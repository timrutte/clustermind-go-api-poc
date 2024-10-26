CREATE TABLE IF NOT EXISTS nodes (
     id INTEGER PRIMARY KEY AUTOINCREMENT,
     title TEXT NOT NULL,
     content TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS connections (
    id INT AUTO_INCREMENT PRIMARY KEY,
    source_id INT NOT NULL,
    target_id INT NOT NULL,
    FOREIGN KEY (source_id) REFERENCES nodes(id) ON DELETE CASCADE,
    FOREIGN KEY (target_id) REFERENCES nodes(id) ON DELETE CASCADE
);

INSERT INTO nodes (title) VALUES ('Node 1'), ('Node 2'), ('Node 3');

INSERT INTO connections (source_id, target_id) VALUES (1, 2), (2, 3), (1, 3);