package repository

import (
	"context"
	"errors"
	"fmt"
	"log/slog"
	"strings"
	"time"

	"gorm.io/gorm"
	"gorm.io/gorm/logger"
)

// gormConfig hace que gorm escriba sus avisos (consultas lentas y errores de SQL) con el
// logger JSON del servicio, en vez de texto con colores.
// ParameterizedQueries: el SQL se registra con "?" en lugar de los valores, para no dejar
// datos en los logs.
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
// El bucle de reintentos ya registra cada intento fallido (warn) y, si se agotan, el error.
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
