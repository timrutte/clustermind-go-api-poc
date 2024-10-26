# Verwende ein Go-Image als Basis
FROM golang:1.22

# Installiere gcc für die sqlite3-Bibliothek
RUN apt-get update && apt-get install -y gcc libsqlite3-dev

# Setze das Arbeitsverzeichnis
WORKDIR /app

# Kopiere die Go-Dateien in das Arbeitsverzeichnis
COPY . .

# Baue die Anwendung
RUN go build -o main .

# Setze den Befehl zum Ausführen der Anwendung
CMD ["./main"]
