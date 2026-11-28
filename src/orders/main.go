package main

import (
	"io"
	"log/slog"
	"net"
	"net/http"
	"net/url"
	"os"
	"time"

	"github.com/gin-gonic/gin"
	"github.com/google/uuid"
	ginprometheus "github.com/zsais/go-gin-prometheus"
	"gorm.io/driver/postgres"
	"gorm.io/gorm"
)

type ShippingAddress struct {
	FirstName string `json:"firstName"`
	LastName  string `json:"lastName"`
	Email     string `json:"email"`
	Address1  string `json:"address1"`
	Address2  string `json:"address2"`
	City      string `json:"city"`
	State     string `json:"state"`
	ZipCode   string `json:"zipCode"`
}

type OrderItem struct {
	ID        uint   `json:"-"         gorm:"primaryKey;autoIncrement"`
	OrderID   string `json:"-"         gorm:"column:order_id;index"`
	ProductID string `json:"productId" gorm:"column:product_id"`
	Name      string `json:"name"      gorm:"column:name"`
	Quantity  int    `json:"quantity"`
	UnitCost  int    `json:"price"     gorm:"column:unit_cost"`
	TotalCost int    `json:"totalCost" gorm:"column:total_cost"`
}

type Order struct {
	ID        string      `json:"id"          gorm:"primaryKey"`
	CreatedAt time.Time   `json:"createdDate"`
	FirstName string      `json:"firstName"   gorm:"column:first_name"`
	LastName  string      `json:"lastName"    gorm:"column:last_name"`
	Email     string      `json:"email"`
	Address1  string      `json:"address1"    gorm:"column:address1"`
	Address2  string      `json:"address2"    gorm:"column:address2"`
	City      string      `json:"city"`
	State     string      `json:"state"`
	ZipCode   string      `json:"zipCode"     gorm:"column:zip_code"`
	Items     []OrderItem `json:"items"       gorm:"foreignKey:OrderID"`
}

type CreateOrderRequest struct {
	ShippingAddress ShippingAddress `json:"shippingAddress"`
	Items           []OrderItem     `json:"items"`
}

var db *gorm.DB

func main() {
	logger := newLogger("orders")
	slog.SetDefault(logger)
	// gin escribe texto en DefaultWriter (por ejemplo, las rutas en modo debug): se descarta
	// para que la salida sea solo JSON.
	gin.DefaultWriter = io.Discard

	dsn := buildDSN()

	var err error
	for i := 0; i < 6; i++ {
		db, err = gorm.Open(postgres.Open(dsn), gormConfig())
		if err == nil {
			break
		}
		slog.Warn("waiting for PostgreSQL", "error", err.Error())
		time.Sleep(5 * time.Second)
	}
	if err != nil {
		fatal("failed to connect to database", err)
	}

	if err := db.AutoMigrate(&Order{}, &OrderItem{}); err != nil {
		fatal("failed to migrate schema", err)
	}

	r := gin.New()
	r.Use(requestLogger(logger, "/health"), recovery(logger))

	p := ginprometheus.NewPrometheus("gin")
	p.Use(r)

	r.GET("/health", func(c *gin.Context) {
		c.String(http.StatusOK, "OK")
	})

	r.GET("/orders", listOrders)
	r.POST("/orders", createOrder)

	port := getEnv("PORT", "8080")
	slog.Info("listening", "port", port)
	if err := r.Run(":" + port); err != nil {
		fatal("listen", err)
	}
}

func createOrder(c *gin.Context) {
	var req CreateOrderRequest
	if err := c.ShouldBindJSON(&req); err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": err.Error()})
		return
	}

	order := Order{
		ID:        uuid.New().String(),
		CreatedAt: time.Now(),
		FirstName: req.ShippingAddress.FirstName,
		LastName:  req.ShippingAddress.LastName,
		Email:     req.ShippingAddress.Email,
		Address1:  req.ShippingAddress.Address1,
		Address2:  req.ShippingAddress.Address2,
		City:      req.ShippingAddress.City,
		State:     req.ShippingAddress.State,
		ZipCode:   req.ShippingAddress.ZipCode,
	}

	for i := range req.Items {
		req.Items[i].OrderID = order.ID
		req.Items[i].TotalCost = req.Items[i].UnitCost * req.Items[i].Quantity
	}
	order.Items = req.Items

	if err := db.Create(&order).Error; err != nil {
		_ = c.Error(err) // el requestLogger lo agrega al log del request
		c.JSON(http.StatusInternalServerError, gin.H{"error": err.Error()})
		return
	}

	c.JSON(http.StatusCreated, order)
}

func listOrders(c *gin.Context) {
	var orders []Order
	db.Preload("Items").Order("created_at desc").Find(&orders)
	c.JSON(http.StatusOK, orders)
}

// buildDSN arma la conexión a PostgreSQL como URL. net/url escapa el usuario y la contraseña:
// la clave que genera RDS lleva puntuación, y en el formato "clave=valor" sin comillas un
// espacio o una comilla rompían la conexión. sslmode es configurable, con require por
// defecto: RDS con PostgreSQL 16 rechaza las conexiones sin TLS.
func buildDSN() string {
	endpoint := getEnv("RETAIL_ORDERS_PERSISTENCE_ENDPOINT", "localhost:5432")
	host, port, err := net.SplitHostPort(endpoint)
	if err != nil { // el endpoint vino sin puerto
		host, port = endpoint, ""
	}
	if port == "" {
		port = "5432"
	}
	query := url.Values{}
	query.Set("sslmode", getEnv("RETAIL_ORDERS_PERSISTENCE_SSLMODE", "require"))
	query.Set("connect_timeout", "5")
	dsn := url.URL{
		Scheme: "postgres",
		User: url.UserPassword(
			getEnv("RETAIL_ORDERS_PERSISTENCE_USERNAME", "retail_user"),
			os.Getenv("RETAIL_ORDERS_PERSISTENCE_PASSWORD"),
		),
		Host:     net.JoinHostPort(host, port),
		Path:     "/" + getEnv("RETAIL_ORDERS_PERSISTENCE_NAME", "orders"),
		RawQuery: query.Encode(),
	}
	return dsn.String()
}

func getEnv(key, fallback string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return fallback
}
