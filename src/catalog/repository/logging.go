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

// slogWriter adapta la interfaz Printf que usa gorm al logger por defecto (slog).
type slogWriter struct{}

func (slogWriter) Printf(format string, args ...interface{}) {
	slog.Warn(strings.TrimSpace(fmt.Sprintf(format, args...)), "component", "gorm")
}
