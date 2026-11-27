package main

import (
	"context"
	"errors"
	"fmt"
	"log/slog"
	"os"
	"strings"
	"time"

	"github.com/gin-gonic/gin"
	"gorm.io/gorm"
	"gorm.io/gorm/logger"
)

// Logs en JSON, una línea por evento, con los mismos campos en los seis servicios:
// time (UTC), level (info, warn, error), service y msg. Los requests suman method,
// path, status y duration_ms. Así CloudWatch Logs Insights filtra por campo.
func newLogger(service string) *slog.Logger {
	h := slog.NewJSONHandler(os.Stdout, &slog.HandlerOptions{
		ReplaceAttr: func(groups []string, a slog.Attr) slog.Attr {
			if len(groups) > 0 {
				return a
			}
			switch a.Key {
			case slog.TimeKey:
				a.Value = slog.StringValue(a.Value.Time().UTC().Format(time.RFC3339Nano))
			case slog.LevelKey:
				a.Value = slog.StringValue(strings.ToLower(a.Value.String()))
			}
			return a
		},
	})
	return slog.New(h).With("service", service)
}

// requestLogger reemplaza al logger de texto de gin. Solo registra la ruta, sin la query
// string, para no dejar datos de los usuarios en los logs. Las rutas de skip (el health
// check) no se registran: en la nube las consulta el balanceador cada pocos segundos.
func requestLogger(l *slog.Logger, skip ...string) gin.HandlerFunc {
	skipped := make(map[string]bool, len(skip))
	for _, p := range skip {
		skipped[p] = true
	}
	return func(c *gin.Context) {
		start := time.Now()
		c.Next()
		path := c.Request.URL.Path
		if skipped[path] {
			return
		}
		status := c.Writer.Status()
		level := slog.LevelInfo
		switch {
		case status >= 500:
			level = slog.LevelError
		case status >= 400:
			level = slog.LevelWarn
		}
		attrs := []slog.Attr{
			slog.String("method", c.Request.Method),
			slog.String("path", path),
			slog.Int("status", status),
			slog.Float64("duration_ms", float64(time.Since(start).Microseconds())/1000),
		}
		if len(c.Errors) > 0 {
			attrs = append(attrs, slog.String("error", c.Errors.String()))
		}
		l.LogAttrs(c.Request.Context(), level, "request", attrs...)
	}
}

// recovery reemplaza al de gin.Default(), que escribe el panic en texto: lo registra en
// JSON y responde 500.
func recovery(l *slog.Logger) gin.HandlerFunc {
	return gin.CustomRecoveryWithWriter(nil, func(c *gin.Context, err any) {
		l.Error("panic", "error", fmt.Sprint(err), "path", c.Request.URL.Path)
		c.AbortWithStatus(500)
	})
}

// fatal registra el error en JSON y termina el proceso, como hacía log.Fatal.
func fatal(msg string, err error) {
	slog.Error(msg, "error", err.Error())
	os.Exit(1)
}

// gormConfig hace que gorm escriba sus avisos (consultas lentas y errores de SQL) con el
// logger JSON, en vez de texto con colores. ParameterizedQueries: el SQL se registra con
// "?" en lugar de los valores, para no dejar datos de los clientes en los logs.
func gormConfig() *gorm.Config {
	return &gorm.Config{
		Logger: logger.New(slogWriter{}, logger.Config{
			SlowThreshold:             200 * time.Millisecond,
			LogLevel:                  logger.Warn,
			IgnoreRecordNotFoundError: true,
			ParameterizedQueries:      true,
			Colorful:                  false,
		}),
	}
}

// openGorm abre la base con gormConfig, pero con el logger de gorm apagado mientras conecta.
// El bucle de reintentos ya registra cada intento fallido (warn) y, si se agotan, el fatal.
// Si gorm también los registrara, un arranque con la base todavía sin levantar sumaría un
// error por intento aunque el servicio termine arrancando bien.
func openGorm(dialector gorm.Dialector) (*gorm.DB, error) {
	cfg := gormConfig()
	normal := cfg.Logger
	cfg.Logger = normal.LogMode(logger.Silent)
	db, err := gorm.Open(dialector, cfg)
	if err != nil {
		return nil, err
	}
	db.Logger = normal
	return db, nil
}

// slogWriter adapta la interfaz Printf que usa gorm al logger por defecto (slog). gorm usa
// este Printf para casi todo lo que registra: consultas lentas, errores de SQL y errores de
// conexión. Si algún argumento es un error, la línea va como error, así una caída de la base
// aparece en el grep de errores y en las alarmas. Van como warn las consultas lentas, que no
// traen error, y un context.Canceled: es el cliente que cortó el request, no una falla del
// servidor ni de la base.
type slogWriter struct{}

func (slogWriter) Printf(format string, args ...interface{}) {
	msg := strings.TrimSpace(fmt.Sprintf(format, args...))
	for _, a := range args {
		if err, ok := a.(error); ok && !errors.Is(err, context.Canceled) {
			slog.Error(msg, "component", "gorm")
			return
		}
	}
	slog.Warn(msg, "component", "gorm")
}
