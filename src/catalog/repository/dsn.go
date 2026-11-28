package repository

import (
	"net"
	"net/url"
	"strconv"

	"retail-store/catalog/config"
)

// postgresDSN arma la conexión a PostgreSQL como URL. net/url escapa el usuario y la
// contraseña: la clave que genera RDS lleva puntuación, y en el formato "clave=valor" sin
// comillas un espacio o una comilla rompían la conexión. sslmode es configurable, con
// require por defecto: RDS con PostgreSQL 16 rechaza las conexiones sin TLS.
func postgresDSN(cfg config.DatabaseConfiguration) string {
	host, port, err := net.SplitHostPort(cfg.Endpoint)
	if err != nil { // el endpoint vino sin puerto
		host, port = cfg.Endpoint, ""
	}
	if port == "" {
		port = "5432"
	}
	sslMode := cfg.SSLMode
	if sslMode == "" {
		sslMode = "require"
	}
	query := url.Values{}
	query.Set("sslmode", sslMode)
	query.Set("connect_timeout", strconv.Itoa(cfg.ConnectTimeout))
	dsn := url.URL{
		Scheme:   "postgres",
		User:     url.UserPassword(cfg.User, cfg.Password),
		Host:     net.JoinHostPort(host, port),
		Path:     "/" + cfg.Name,
		RawQuery: query.Encode(),
	}
	return dsn.String()
}
