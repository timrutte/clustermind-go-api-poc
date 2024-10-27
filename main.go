package main

import (
	"context"
	"database/sql"
	"encoding/json"
	"fmt"
	"log"
	"net/http"
	"os"

	"github.com/aws/aws-lambda-go/events"
	"github.com/aws/aws-lambda-go/lambda"
	_ "github.com/go-sql-driver/mysql"
)

// Node defines the structure of a Node
type Node struct {
	ID      int    `json:"id"`
	Title   string `json:"title"`
	Content string `json:"content"`
}

// Edge defines the structure of an edge between Nodes
type Edge struct {
	SourceID int `json:"source_id"`
	TargetId int `json:"target_id"`
}

// CombinedData defines the structure for combined data
type CombinedData struct {
	NodeData []Node `json:"nodes"`
	EdgeData []Edge `json:"edges"`
}

// DB is the global database connection
var db *sql.DB

// Handler for creating a new Node
func createNodeHandler(ctx context.Context, request events.APIGatewayProxyRequest) (events.APIGatewayProxyResponse, error) {
	var newNode Node

	if err := json.Unmarshal([]byte(request.Body), &newNode); err != nil {
		return events.APIGatewayProxyResponse{StatusCode: http.StatusBadRequest, Body: err.Error()}, nil
	}

	if newNode.Title == "" || newNode.Content == "" {
		return events.APIGatewayProxyResponse{StatusCode: http.StatusBadRequest, Body: "Title and Content cannot be empty"}, nil
	}

	stmt, err := db.Prepare("INSERT INTO nodes(title, content) VALUES(?, ?)")
	if err != nil {
		return events.APIGatewayProxyResponse{StatusCode: http.StatusInternalServerError, Body: err.Error()}, nil
	}
	defer stmt.Close()

	res, err := stmt.Exec(newNode.Title, newNode.Content)
	if err != nil {
		return events.APIGatewayProxyResponse{StatusCode: http.StatusInternalServerError, Body: err.Error()}, nil
	}

	id, err := res.LastInsertId()
	if err != nil {
		return events.APIGatewayProxyResponse{StatusCode: http.StatusInternalServerError, Body: err.Error()}, nil
	}
	newNode.ID = int(id)

	response, err := json.Marshal(newNode)
	if err != nil {
		return events.APIGatewayProxyResponse{StatusCode: http.StatusInternalServerError, Body: err.Error()}, nil
	}

	return events.APIGatewayProxyResponse{StatusCode: http.StatusCreated, Body: string(response)}, nil
}

// Handler for retrieving all nodes and edges
func getNodesHandler(ctx context.Context, request events.APIGatewayProxyRequest) (events.APIGatewayProxyResponse, error) {
	rows, err := db.Query("SELECT id, title, content FROM nodes")
	if err != nil {
		return events.APIGatewayProxyResponse{StatusCode: http.StatusInternalServerError, Body: err.Error()}, nil
	}
	defer rows.Close()

	var nodes []Node
	for rows.Next() {
		var node Node
		if err := rows.Scan(&node.ID, &node.Title, &node.Content); err != nil {
			return events.APIGatewayProxyResponse{StatusCode: http.StatusInternalServerError, Body: err.Error()}, nil
		}
		nodes = append(nodes, node)
	}

	edgesRows, err := db.Query("SELECT source_id, target_id FROM connections")
	if err != nil {
		return events.APIGatewayProxyResponse{StatusCode: http.StatusInternalServerError, Body: err.Error()}, nil
	}
	defer edgesRows.Close()

	var edges []Edge
	for edgesRows.Next() {
		var edge Edge
		if err := edgesRows.Scan(&edge.SourceID, &edge.TargetId); err != nil {
			return events.APIGatewayProxyResponse{StatusCode: http.StatusInternalServerError, Body: err.Error()}, nil
		}
		edges = append(edges, edge)
	}

	combinedData := CombinedData{
		NodeData: nodes,
		EdgeData: edges,
	}

	response, err := json.Marshal(combinedData)
	if err != nil {
		return events.APIGatewayProxyResponse{StatusCode: http.StatusInternalServerError, Body: err.Error()}, nil
	}

	return events.APIGatewayProxyResponse{StatusCode: http.StatusOK, Body: string(response)}, nil
}

// Health check handler
func healthHandler(ctx context.Context, request events.APIGatewayProxyRequest) (events.APIGatewayProxyResponse, error) {
	return events.APIGatewayProxyResponse{
		StatusCode: http.StatusOK,
		Body:       `{"status":"ok"}`,
	}, nil
}

func InitDB() {
	var err error
	dsn := fmt.Sprintf("%s:%s@tcp(%s:%s)/%s",
		os.Getenv("DB_USER"),
		os.Getenv("DB_PASSWORD"),
		os.Getenv("DB_HOST"),
		os.Getenv("DB_PORT"),
		os.Getenv("DB_NAME"),
	)

	db, err = sql.Open("mysql", dsn)
	if err != nil {
		log.Fatalf("Database is not accessible: %v", err)
	}

	if err := db.Ping(); err != nil {
		log.Fatalf("Database is not accessible: %v", err)
	}
}

func main() {
	log.Println("Starting the application...")

	InitDB()
	defer db.Close()

	// Mapping HTTP methods and paths to handler functions
	lambda.Start(func(ctx context.Context, request events.APIGatewayProxyRequest) (events.APIGatewayProxyResponse, error) {
		switch {
		case request.HTTPMethod == http.MethodPost && request.Path == "/nodes":
			return createNodeHandler(ctx, request)
		case request.HTTPMethod == http.MethodGet && request.Path == "/nodes":
			return getNodesHandler(ctx, request)
		case request.HTTPMethod == http.MethodGet && request.Path == "/health":
			return healthHandler(ctx, request)
		default:
			return events.APIGatewayProxyResponse{StatusCode: http.StatusNotFound, Body: "Not found"}, nil
		}
	})
}
