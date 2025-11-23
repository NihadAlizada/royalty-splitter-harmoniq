-- =====================================================
-- Creator Royalty Splitter - Final SQL
-- Designed for PostgreSQL 15–18 (Open with PgAdmin 4 please as I said)
-- =====================================================

DROP TABLE IF EXISTS SIEM_Event CASCADE;
DROP TABLE IF EXISTS Payout CASCADE;
DROP TABLE IF EXISTS Wallet CASCADE;
DROP TABLE IF EXISTS Split CASCADE;
DROP TABLE IF EXISTS Royalty CASCADE;
DROP TABLE IF EXISTS StreamData CASCADE;
DROP TABLE IF EXISTS Track CASCADE;
DROP TABLE IF EXISTS SeverityLevel CASCADE;
DROP TABLE IF EXISTS PayoutStatus CASCADE;
DROP TABLE IF EXISTS UserAccount CASCADE;
DROP TABLE IF EXISTS Role CASCADE;

--Smart contract tables drop
DROP TABLE IF EXISTS BlockchainEvent CASCADE;
DROP TABLE IF EXISTS ContractDeploymentLog CASCADE;
DROP TABLE IF EXISTS SmartContract CASCADE;

DROP MATERIALIZED VIEW IF EXISTS mv_stream_summary CASCADE;
DROP FUNCTION IF EXISTS refresh_mv_stream_summary();

-- =====================================================
-- 1) Lookup / Enum tables
-- =====================================================
CREATE TABLE Role (
    role_id SERIAL PRIMARY KEY,
    role_name VARCHAR(50) NOT NULL UNIQUE
);

CREATE TABLE PayoutStatus (
    status_id SERIAL PRIMARY KEY,
    status_name VARCHAR(50) NOT NULL UNIQUE
);

CREATE TABLE SeverityLevel (
    severity_id SERIAL PRIMARY KEY,
    severity_name VARCHAR(50) NOT NULL UNIQUE
);

-- =====================================================
-- 2) Core OLTP tables
-- =====================================================
CREATE TABLE UserAccount (
    user_id SERIAL PRIMARY KEY,
    name VARCHAR(100) NOT NULL,
    email VARCHAR(100) UNIQUE NOT NULL,
    password_hash VARCHAR(255) NOT NULL,
    role_id INT REFERENCES Role(role_id) ON DELETE SET NULL,
    country VARCHAR(100)
);

CREATE TABLE Track (
    track_id SERIAL PRIMARY KEY,
    title VARCHAR(200) NOT NULL,
    duration FLOAT,
    release_date DATE,
    nft_id VARCHAR(255),
    owner_id INT REFERENCES UserAccount(user_id) ON DELETE SET NULL
);

CREATE TABLE StreamData (
    stream_id SERIAL PRIMARY KEY,
    track_id INT NOT NULL REFERENCES Track(track_id) ON DELETE CASCADE,
    platform VARCHAR(100),
    stream_count INT DEFAULT 0,
    date_recorded DATE NOT NULL,
    fraud_flag BOOLEAN DEFAULT FALSE
);

CREATE TABLE Royalty (
    royalty_id SERIAL PRIMARY KEY,
    track_id INT NOT NULL REFERENCES Track(track_id) ON DELETE CASCADE,
    total_earning DECIMAL(12,2) NOT NULL,
    distribution_date DATE
);

CREATE TABLE Split (
    split_id SERIAL PRIMARY KEY,
    track_id INT NOT NULL REFERENCES Track(track_id) ON DELETE CASCADE,
    user_id INT NOT NULL REFERENCES UserAccount(user_id) ON DELETE CASCADE,
    percentage FLOAT NOT NULL CHECK (percentage >= 0 AND percentage <= 100),
    UNIQUE (track_id, user_id)
);

CREATE TABLE Wallet (
    wallet_id SERIAL PRIMARY KEY,
    user_id INT NOT NULL UNIQUE REFERENCES UserAccount(user_id) ON DELETE CASCADE,
    balance DECIMAL(12,2) DEFAULT 0,
    last_updated TIMESTAMP,
    blockchain_address VARCHAR(255)
);

CREATE TABLE Payout (
    payout_id SERIAL PRIMARY KEY,
    wallet_id INT NOT NULL REFERENCES Wallet(wallet_id) ON DELETE CASCADE,
    amount DECIMAL(12,2) NOT NULL,
    txn_date TIMESTAMP NOT NULL DEFAULT NOW(),
    status_id INT REFERENCES PayoutStatus(status_id),
    blockchain_txn_id VARCHAR(255)
);

CREATE TABLE SIEM_Event (
    event_id SERIAL PRIMARY KEY,
    user_id INT REFERENCES UserAccount(user_id) ON DELETE SET NULL,
    event_type VARCHAR(100) NOT NULL,
    severity_id INT REFERENCES SeverityLevel(severity_id),
    timestamp TIMESTAMP NOT NULL DEFAULT NOW(),
    description TEXT
);

-- =====================================================
-- 2.1 Smart Contract Integration Tables
-- =====================================================

-- Stores deployed contract metadata (local or testnet)
CREATE TABLE SmartContract (
    contract_id SERIAL PRIMARY KEY,
    name VARCHAR(100) NOT NULL,
    address VARCHAR(255) NOT NULL UNIQUE,
    network VARCHAR(100) NOT NULL,               -- "localhost" or "sepolia" I will use that later
    abi JSONB NOT NULL,                          -- full ABI used by frontend & ETL
    deployed_at TIMESTAMP NOT NULL DEFAULT NOW()
);

-- Deployment history
CREATE TABLE ContractDeploymentLog (
    deployment_id SERIAL PRIMARY KEY,
    contract_id INT REFERENCES SmartContract(contract_id) ON DELETE CASCADE,
    tx_hash VARCHAR(255),
    block_number BIGINT,
    deployed_by VARCHAR(255),
    deployed_at TIMESTAMP DEFAULT NOW()
);

-- On-chain Events stored by ETL
CREATE TABLE BlockchainEvent (
    event_id SERIAL PRIMARY KEY,
    contract_id INT REFERENCES SmartContract(contract_id) ON DELETE CASCADE,
    event_name VARCHAR(100) NOT NULL,                -- e.g., "SplitSet", "RoyaltyPaid"
    block_number BIGINT,
    tx_hash VARCHAR(255),
    log_index INT,
    payload JSONB NOT NULL,                          -- decoded event fields
    processed_at TIMESTAMP DEFAULT NOW(),
    UNIQUE(tx_hash, log_index)                       -- idempotency for ETL
);

-- Indexes for high-speed processing
CREATE INDEX idx_bc_event_tx ON BlockchainEvent(tx_hash);
CREATE INDEX idx_bc_event_name ON BlockchainEvent(event_name);
CREATE INDEX idx_bc_event_block ON BlockchainEvent(block_number);

-- =====================================================
-- 3) Hot-path indexes
-- =====================================================
CREATE INDEX idx_track_owner ON Track(owner_id);
CREATE INDEX idx_track_nft ON Track(nft_id);

CREATE INDEX idx_stream_track ON StreamData(track_id);
CREATE INDEX idx_stream_date ON StreamData(date_recorded);
CREATE INDEX idx_stream_platform ON StreamData(platform);
CREATE INDEX idx_stream_fraud ON StreamData(fraud_flag);

CREATE INDEX idx_split_track ON Split(track_id);
CREATE INDEX idx_split_user ON Split(user_id);

CREATE INDEX idx_wallet_user ON Wallet(user_id);
CREATE INDEX idx_payout_wallet ON Payout(wallet_id);
CREATE INDEX idx_payout_txn ON Payout(blockchain_txn_id);

CREATE INDEX idx_siem_user ON SIEM_Event(user_id);
CREATE INDEX idx_siem_severity ON SIEM_Event(severity_id);

-- =====================================================
-- 4) Materialized view for dashboard
-- =====================================================
CREATE MATERIALIZED VIEW mv_stream_summary AS
SELECT
    sd.track_id,
    COUNT(*) AS stream_rows,
    SUM(sd.stream_count) AS total_streams,
    MIN(sd.date_recorded) AS first_stream_date,
    MAX(sd.date_recorded) AS last_stream_date,
    SUM(CASE WHEN sd.fraud_flag THEN 1 ELSE 0 END) AS fraud_count
FROM StreamData sd
GROUP BY sd.track_id
WITH NO DATA;

CREATE INDEX idx_mv_stream_summary_track ON mv_stream_summary(track_id);

CREATE OR REPLACE FUNCTION refresh_mv_stream_summary()
RETURNS VOID LANGUAGE plpgsql AS $$
BEGIN
    REFRESH MATERIALIZED VIEW mv_stream_summary;
END;
$$;

-- =====================================================
-- 5) Seed data
-- =====================================================

-- Roles
INSERT INTO Role (role_name) VALUES ('Artist') ON CONFLICT DO NOTHING;
INSERT INTO Role (role_name) VALUES ('Admin') ON CONFLICT DO NOTHING;
INSERT INTO Role (role_name) VALUES ('SecurityManager') ON CONFLICT DO NOTHING;

-- Payout statuses
INSERT INTO PayoutStatus (status_name) VALUES ('Pending') ON CONFLICT DO NOTHING;
INSERT INTO PayoutStatus (status_name) VALUES ('Completed') ON CONFLICT DO NOTHING;
INSERT INTO PayoutStatus (status_name) VALUES ('Failed') ON CONFLICT DO NOTHING;

-- Severity levels
INSERT INTO SeverityLevel (severity_name) VALUES ('Low') ON CONFLICT DO NOTHING;
INSERT INTO SeverityLevel (severity_name) VALUES ('Medium') ON CONFLICT DO NOTHING;
INSERT INTO SeverityLevel (severity_name) VALUES ('High') ON CONFLICT DO NOTHING;

-- Sample Users
INSERT INTO UserAccount (name, email, password_hash, role_id, country)
VALUES
 ('Alice Artist', 'alice@example.com', 'fakehash1', (SELECT role_id FROM Role WHERE role_name='Artist'), 'Azerbaijan')
ON CONFLICT DO NOTHING;

INSERT INTO UserAccount (name, email, password_hash, role_id, country)
VALUES
 ('Bob Admin', 'bob@example.com', 'fakehash2', (SELECT role_id FROM Role WHERE role_name='Admin'), 'Azerbaijan')
ON CONFLICT DO NOTHING;

-- Sample Track
INSERT INTO Track (title, duration, release_date, nft_id, owner_id)
VALUES ('Demo Track', 210, '2025-01-01', 'NFT-0001', (SELECT user_id FROM UserAccount WHERE email='alice@example.com'))
ON CONFLICT DO NOTHING;

-- Sample StreamData
INSERT INTO StreamData (track_id, platform, stream_count, date_recorded, fraud_flag)
VALUES
 ((SELECT track_id FROM Track WHERE nft_id='NFT-0001'), 'YouTube', 1000, '2025-11-01', FALSE),
 ((SELECT track_id FROM Track WHERE nft_id='NFT-0001'), 'Spotify', 500, '2025-11-02', FALSE),
 ((SELECT track_id FROM Track WHERE nft_id='NFT-0001'), 'FakeStreamProvider', 6000, '2025-11-02', TRUE)
ON CONFLICT DO NOTHING;

-- Sample Split
INSERT INTO Split (track_id, user_id, percentage)
VALUES ((SELECT track_id FROM Track WHERE nft_id='NFT-0001'),
        (SELECT user_id FROM UserAccount WHERE email='alice@example.com'),
        100.0)
ON CONFLICT DO NOTHING;

-- Wallet for Alice
INSERT INTO Wallet (user_id, balance, last_updated, blockchain_address)
VALUES ((SELECT user_id FROM UserAccount WHERE email='alice@example.com'), 0, NOW(), '0xabc123...')
ON CONFLICT DO NOTHING;

-- Royalty record
INSERT INTO Royalty (track_id, total_earning, distribution_date)
VALUES ((SELECT track_id FROM Track WHERE nft_id='NFT-0001'), 150.00, '2025-11-03')
ON CONFLICT DO NOTHING;

-- Payout record
INSERT INTO Payout (wallet_id, amount, txn_date, status_id, blockchain_txn_id)
VALUES (
  (SELECT wallet_id FROM Wallet WHERE blockchain_address='0xabc123...'),
  150.00,
  NOW(),
  (SELECT status_id FROM PayoutStatus WHERE status_name='Completed'),
  '0xblockchaintx123'
)
ON CONFLICT DO NOTHING;

-- SIEM Event
INSERT INTO SIEM_Event (user_id, event_type, severity_id, description)
VALUES ((SELECT user_id FROM UserAccount WHERE email='bob@example.com'), 'admin-login', (SELECT severity_id FROM SeverityLevel WHERE severity_name='Low'), 'Admin Bob logged in');

-- Smart contract seed (local Hardhat)
INSERT INTO SmartContract (name, address, network, abi)
VALUES (
  'RoyaltySplitter',
  '0x5FbDB2315678afecb367f032d93F642f64180aa3',
  'localhost',
  '[]'::jsonb       -- ABI will be pasted here by ETL or manually
)
ON CONFLICT DO NOTHING;

-- Populate the materialized view
SELECT refresh_mv_stream_summary();

-- =====================================================
-- Hi Teacher
-- =====================================================
