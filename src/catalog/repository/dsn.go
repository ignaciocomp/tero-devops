package repository

import (
	"fmt"
	"net"
	"net/url"
	"strconv"
	"strings"

	"retail-store/catalog/config"
)

// postgresDSN arma la conexión a PostgreSQL como URL. net/url escapa el usuario y la
// contraseña: la clave que genera RDS lleva puntuación, y en el formato "clave=valor" sin
// comillas un espacio o una comilla rompían la conexión.
func postgresDSN(cfg config.DatabaseConfiguration) (string, error) {
	sslMode, err := checkSSLMode(cfg.SSLMode)
	if err != nil {
		return "", err
	}
	host, port, err := net.SplitHostPort(cfg.Endpoint)
	if err != nil { // el endpoint vino sin puerto (los corchetes de un IPv6 los vuelve a poner JoinHostPort)
		host, port = strings.TrimSuffix(strings.TrimPrefix(cfg.Endpoint, "["), "]"), ""
	}
	if port == "" {
		port = "5432"
	}
	query := url.Values{}
	query.Set("sslmode", sslMode)
	query.Set("connect_timeout", strconv.Itoa(cfg.ConnectTimeout))
	// Para ver en pg_stat_activity qué servicio tiene cada conexión.
	query.Set("application_name", "catalog")
	dsn := url.URL{
		Scheme:   "postgres",
		User:     url.UserPassword(cfg.User, cfg.Password),
		Host:     net.JoinHostPort(host, port),
		Path:     "/" + cfg.Name,
		RawQuery: query.Encode(),
	}
	return dsn.String(), nil
}

// checkSSLMode acepta los mismos tres valores que los otros servicios con base. require es el
// valor por defecto (también con la variable vacía): RDS con PostgreSQL 16 rechaza las
// conexiones sin TLS. prefer y allow no se aceptan, porque pueden caer a texto plano.
func checkSSLMode(mode string) (string, error) {
	switch mode {
	case "":
		return "require", nil
	case "disable", "require", "verify-full":
		return mode, nil
	}
	return "", fmt.Errorf("unsupported RETAIL_CATALOG_PERSISTENCE_SSLMODE %q: use disable, require or verify-full", mode)
}
