package repository

import (
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

// slogWriter adapta la interfaz Printf que usa gorm al logger por defecto (slog). gorm usa
// este único Printf para todo: consultas lentas, errores de SQL y errores de conexión. Si
// algún argumento es un error, la línea va como error, así una caída de la base aparece en
// el grep de errores y en las alarmas. Las consultas lentas siguen como warn.
type slogWriter struct{}

func (slogWriter) Printf(format string, args ...interface{}) {
	msg := strings.TrimSpace(fmt.Sprintf(format, args...))
	for _, a := range args {
		if _, ok := a.(error); ok {
			slog.Error(msg, "component", "gorm")
			return
		}
	}
	slog.Warn(msg, "component", "gorm")
}
