PRAGMA encoding = 'UTF-8';
CREATE TABLE IF NOT EXISTS mtg (
    ID INTEGER PRIMARY KEY AUTOINCREMENT,
    Name VARCHAR(56) NOT NULL,
    Oracle  VARCHAR(6096),
    ManaCost VARCHAR(20),
    Edition VARCHAR(56),
    Type VARCHAR(56),
    CardNumber VARCHAR(255),
    Preis DECIMAL(10,2),
    Image BLOB,
    Rawdata BLOB,
    UNIQUE (Name, Edition) ON CONFLICT IGNORE
);
