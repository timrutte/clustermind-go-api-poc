package main

import (
	"database/sql"
	"encoding/json"
	"fmt"
	"log"
	"net/http"

	_ "github.com/go-sql-driver/mysql"
	"github.com/gorilla/mux"
)

// Node definiert die Struktur einer Node
type Node struct {
	ID      int    `json:"id"`
	Title   string `json:"title"`
	Content string `json:"content"`
}

// Edge definiert die Struktur einer Verbindung zwischen Nodes
type Edge struct {
	SourceID int `json:"source_id"`
	TargetId int `json:"target_id"`
}

// CombinedData definiert die Struktur für kombinierte Daten
type CombinedData struct {
	NodeData []Node `json:"nodes"`
	EdgeData []Edge `json:"edges"` // Hinzufügen von Edgedaten
}

// DB ist die globale Datenbankverbindung
var db *sql.DB

// createNodeHandler behandelt das Erstellen einer neuen Node
func createNodeHandler(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		http.Error(w, "Method not allowed", http.StatusMethodNotAllowed)
		return
	}

	var newNode Node

	// Decodierung des JSON-Körpers in die Node-Struktur
	if err := json.NewDecoder(r.Body).Decode(&newNode); err != nil {
		http.Error(w, err.Error(), http.StatusBadRequest)
		return
	}

	// Hier könnten zusätzliche Validierungen stattfinden, z.B.:
	if newNode.Title == "" {
		http.Error(w, "Title cannot be empty", http.StatusBadRequest)
		return
	}
	if newNode.Content == "" {
		http.Error(w, "Content cannot be empty", http.StatusBadRequest)
		return
	}

	// Speichern der neuen Node in der Datenbank
	stmt, err := db.Prepare("INSERT INTO nodes(title, content) VALUES(?, ?)")
	if err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}
	defer stmt.Close()

	res, err := stmt.Exec(newNode.Title, newNode.Content)
	if err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}

	// ID des neu erstellten Eintrags abrufen
	id, err := res.LastInsertId()
	if err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}
	newNode.ID = int(id)

	// Antwort mit der erstellten Node zurückgeben
	w.WriteHeader(http.StatusCreated)
	json.NewEncoder(w).Encode(newNode)
}

func getNodesHandler(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Content-Type", "application/json")

	// Abrufen aller Nodes aus der Datenbank
	rows, err := db.Query("SELECT id, title, content FROM nodes")
	if err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}
	defer rows.Close()

	var nodes []Node

	for rows.Next() {
		var node Node
		if err := rows.Scan(&node.ID, &node.Title, &node.Content); err != nil {
			http.Error(w, err.Error(), http.StatusInternalServerError)
			return
		}
		nodes = append(nodes, node)
	}

	// Abrufen aller Edges aus der Datenbank
	edgesRows, err := db.Query("SELECT source_id, target_id FROM connections")
	if err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}
	defer edgesRows.Close()

	var edges []Edge
	for edgesRows.Next() {
		var edge Edge
		if err := edgesRows.Scan(&edge.SourceID, &edge.TargetId); err != nil {
			http.Error(w, err.Error(), http.StatusInternalServerError)
			return
		}
		edges = append(edges, edge)
	}

	// Kombinierte Datenstruktur
	combinedData := CombinedData{
		NodeData: nodes,
		EdgeData: edges, // Rückgabe der Edgedaten
	}

	// Antwort mit den kombinierten Daten zurückgeben
	json.NewEncoder(w).Encode(combinedData)
}

// corsMiddleware fügt CORS-Header zu den Antworten hinzu
func corsMiddleware(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Access-Control-Allow-Origin", "*")
		w.Header().Set("Access-Control-Allow-Methods", "GET, POST, OPTIONS")
		w.Header().Set("Access-Control-Allow-Headers", "Content-Type")

		// Preflight-Anfrage (OPTIONS) sofort beantworten
		if r.Method == http.MethodOptions {
			w.WriteHeader(http.StatusOK)
			return
		}

		next.ServeHTTP(w, r)
	})
}

func InitDB() {
	var err error
	// Die Umgebungsvariablen zum Verbinden mit MySQL lesen
	dsn := fmt.Sprintf("%s:%s@tcp(%s:%s)/%s",
		"root",     // MYSQL_USER
		"password", // MYSQL_PASSWORD
		"db",       // MYSQL_HOST
		"3306",     // MYSQL_PORT
		"nodes_db", // MYSQL_DB
	)

	db, err = sql.Open("mysql", dsn)
	if err != nil {
		log.Fatalf("Datenbank ist nicht erreichbar: %v", err)
	}

	// Teste die Verbindung zur Datenbank
	if err := db.Ping(); err != nil {
		log.Fatalf("Datenbank ist nicht erreichbar: %v", err)
	}
}

func main() {
	InitDB()
	defer db.Close()

	r := mux.NewRouter()

	// Endpunkte definieren
	r.HandleFunc("/nodes", createNodeHandler).Methods("POST")
	r.HandleFunc("/nodes", getNodesHandler).Methods("GET")

	// Middleware für CORS hinzufügen
	http.Handle("/", corsMiddleware(r))

	// Server starten
	log.Println("Server runs on port 8080...")
	if err := http.ListenAndServe(":8080", nil); err != nil {
		log.Fatal(err)
	}
}
