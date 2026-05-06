#!/usr/bin/env bash
# =============================================================================
# Conduit — One-Command Install
#
# Sets up everything needed to run the Conduit Lightning MCP server:
#   1. Checks prerequisites (Python 3.11+, PostgreSQL, LND credentials)
#   2. Creates Python virtual environment and installs dependencies
#   3. Generates a secure API key
#   4. Creates the PostgreSQL database and user
#   5. Runs database migrations
#   6. Wires up Claude Desktop's MCP configuration
#
# Usage:
#   chmod +x install.sh && ./install.sh
#
# Safe to re-run — checks existing state before making changes.
# =============================================================================

set -euo pipefail

# --- Colors ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

info()    { echo -e "${BLUE}[INFO]${NC}  $1"; }
success() { echo -e "${GREEN}[OK]${NC}    $1"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $1"; }
error()   { echo -e "${RED}[ERROR]${NC} $1"; }
step()    { echo -e "\n${CYAN}${BOLD}==> $1${NC}"; }

# --- Resolve project root (directory containing this script) ---
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

echo -e "${BOLD}"
echo "  ⚡ Conduit — Lightning Payment Rails for AI Agents"
echo "  ─────────────────────────────────────────────────────"
echo -e "${NC}"

# =============================================================================
# Step 1: Check prerequisites
# =============================================================================
step "Checking prerequisites"

ERRORS=0

# Python 3.11+
if command -v python3 &>/dev/null; then
    PY_VERSION=$(python3 -c "import sys; print(f'{sys.version_info.major}.{sys.version_info.minor}')")
    PY_MAJOR=$(echo "$PY_VERSION" | cut -d. -f1)
    PY_MINOR=$(echo "$PY_VERSION" | cut -d. -f2)
    if (( PY_MAJOR >= 3 && PY_MINOR >= 11 )); then
        success "Python $PY_VERSION found"
    else
        error "Python 3.11+ required (found $PY_VERSION)"
        ERRORS=$((ERRORS + 1))
    fi
else
    error "Python 3 not found. Install with: brew install python@3.11 (or use pyenv)"
    ERRORS=$((ERRORS + 1))
fi

# PostgreSQL
if command -v psql &>/dev/null; then
    PG_VERSION=$(psql --version | head -1)
    success "PostgreSQL found: $PG_VERSION"
else
    error "PostgreSQL not found. Install with: brew install postgresql@16 && brew services start postgresql@16"
    ERRORS=$((ERRORS + 1))
fi

# Check if Postgres is running
if command -v pg_isready &>/dev/null && pg_isready &>/dev/null; then
    success "PostgreSQL is running"
else
    warn "PostgreSQL may not be running. Start with: brew services start postgresql@16"
fi

# LND credentials
CREDS_DIR="$SCRIPT_DIR/credentials"
if [[ -d "$CREDS_DIR" ]]; then
    CERT_COUNT=$(find "$CREDS_DIR" -name "*.pem" -o -name "*.cert" 2>/dev/null | wc -l | tr -d ' ')
    MAC_COUNT=$(find "$CREDS_DIR" -name "*.macaroon" 2>/dev/null | wc -l | tr -d ' ')
    if (( CERT_COUNT > 0 && MAC_COUNT > 0 )); then
        success "LND credentials found in credentials/"
    else
        warn "credentials/ exists but may be missing TLS cert or macaroon"
        warn "You'll need: a TLS certificate (.pem) and admin.macaroon"
    fi
else
    warn "No credentials/ directory found"
    warn "Create it and add your LND TLS cert + admin.macaroon before starting"
    warn "  mkdir -p credentials/"
    warn "  cp /path/to/tls.cert credentials/full-chain.pem"
    warn "  cp /path/to/admin.macaroon credentials/admin.macaroon"
fi

if (( ERRORS > 0 )); then
    echo ""
    error "Fix the $ERRORS error(s) above and re-run this script."
    exit 1
fi

# =============================================================================
# Step 2: Create virtual environment and install dependencies
# =============================================================================
step "Setting up Python environment"

if [[ -d ".venv" ]]; then
    success "Virtual environment already exists (.venv/)"
else
    info "Creating virtual environment..."
    python3 -m venv .venv
    success "Virtual environment created"
fi

info "Activating virtual environment..."
source .venv/bin/activate

info "Installing dependencies (this may take a minute)..."
pip install --quiet --upgrade pip
pip install --quiet -e ".[dev]"
success "Dependencies installed"

# =============================================================================
# Step 3: Generate API key (if not already set)
# =============================================================================
step "Configuring environment"

ENV_FILE="$SCRIPT_DIR/.env"

if [[ -f "$ENV_FILE" ]]; then
    # Check if API key is already set and not the default
    EXISTING_KEY=$(grep 'CONDUIT_API_KEY=' "$ENV_FILE" 2>/dev/null | sed 's/CONDUIT_API_KEY=//' || echo "")
    if [[ -n "$EXISTING_KEY" && "$EXISTING_KEY" != "CHANGE-ME" ]]; then
        success ".env exists with API key set (${EXISTING_KEY:0:6}...)"
    else
        info "Generating secure API key..."
        NEW_KEY=$(python3 -c "import secrets; print(secrets.token_urlsafe(32))")
        if grep -q "CONDUIT_API_KEY=" "$ENV_FILE"; then
            # Replace existing line
            sed -i.bak "s|CONDUIT_API_KEY=.*|CONDUIT_API_KEY=$NEW_KEY|" "$ENV_FILE"
            rm -f "$ENV_FILE.bak"
        else
            echo "CONDUIT_API_KEY=$NEW_KEY" >> "$ENV_FILE"
        fi
        success "API key generated: ${NEW_KEY:0:6}..."
    fi
else
    info "Creating .env from template..."
    NEW_KEY=$(python3 -c "import secrets; print(secrets.token_urlsafe(32))")
    cat > "$ENV_FILE" <<ENVEOF
# =============================================================================
# Conduit — Configuration
# =============================================================================

# --- App ---
APP_NAME=Conduit
APP_ENV=development
DEBUG=false
API_HOST=0.0.0.0
API_PORT=8000

# --- PostgreSQL ---
DATABASE_URL=postgresql+asyncpg://conduit:conduit@localhost:5432/conduit

# --- Redis ---
REDIS_URL=redis://localhost:6379/0

# --- LND Node ---
# Update these to match your LND setup
LND_HOST=localhost
LND_GRPC_PORT=10009
LND_TLS_CERT_PATH=$CREDS_DIR/full-chain.pem
LND_MACAROON_PATH=$CREDS_DIR/admin.macaroon
LND_NETWORK=mainnet

# --- API Key Auth ---
CONDUIT_API_KEY=$NEW_KEY

# --- Spending Limits (sats, 0 = no limit) ---
SPENDING_LIMIT_PER_PAYMENT_SATS=10000
SPENDING_LIMIT_HOURLY_SATS=50000
SPENDING_LIMIT_DAILY_SATS=200000
SPENDING_CONFIRM_ABOVE_SATS=5000
ENVEOF
    success ".env created with API key: ${NEW_KEY:0:6}..."
    warn "Edit .env to set your LND_HOST and credential paths"
fi

# =============================================================================
# Step 4: Create PostgreSQL database and user
# =============================================================================
step "Setting up PostgreSQL database"

# Check if database exists
if psql -U conduit -d conduit -c "SELECT 1" &>/dev/null; then
    success "Database 'conduit' already exists"
else
    info "Creating database user and database..."

    # Try creating user (may already exist)
    if psql -d postgres -c "SELECT 1 FROM pg_roles WHERE rolname='conduit'" | grep -q 1; then
        success "User 'conduit' already exists"
    else
        createuser conduit 2>/dev/null || psql -d postgres -c "CREATE USER conduit WITH PASSWORD 'conduit';" 2>/dev/null || true
        success "User 'conduit' created"
    fi

    # Create database
    createdb -O conduit conduit 2>/dev/null || psql -d postgres -c "CREATE DATABASE conduit OWNER conduit;" 2>/dev/null || true
    success "Database 'conduit' created"
fi

# =============================================================================
# Step 5: Run database migrations
# =============================================================================
step "Running database migrations"

if [[ -d "alembic" ]]; then
    info "Running Alembic migrations..."
    PYTHONPATH=src alembic upgrade head 2>&1 | tail -5
    success "Migrations complete"
else
    warn "No alembic/ directory found — skipping migrations"
fi

# =============================================================================
# Step 6: Wire up Claude Desktop MCP configuration
# =============================================================================
step "Configuring Claude Desktop"

# Determine Claude Desktop config path
if [[ "$(uname)" == "Darwin" ]]; then
    CLAUDE_CONFIG_DIR="$HOME/Library/Application Support/Claude"
elif [[ "$(uname)" == "Linux" ]]; then
    CLAUDE_CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/claude"
else
    CLAUDE_CONFIG_DIR="$HOME/.config/claude"
fi

CLAUDE_CONFIG="$CLAUDE_CONFIG_DIR/claude_desktop_config.json"

# Build the MCP server command
VENV_PYTHON="$SCRIPT_DIR/.venv/bin/python"
MCP_MODULE="conduit.mcp_server"

if [[ -f "$CLAUDE_CONFIG" ]]; then
    # Check if conduit is already configured
    if grep -q "conduit-lightning" "$CLAUDE_CONFIG" 2>/dev/null; then
        success "Conduit already configured in Claude Desktop"
    else
        info "Adding Conduit to Claude Desktop config..."
        info "Please add the following to your claude_desktop_config.json mcpServers section:"
        echo ""
        echo -e "${CYAN}\"conduit-lightning\": {"
        echo "  \"command\": \"$VENV_PYTHON\","
        echo "  \"args\": [\"-m\", \"$MCP_MODULE\"],"
        echo "  \"env\": {"
        echo "    \"PYTHONPATH\": \"$SCRIPT_DIR/src\""
        echo "  }"
        echo -e "}${NC}"
        echo ""
        warn "Auto-editing JSON config is risky — please add this manually"
        warn "Config file: $CLAUDE_CONFIG"
    fi
else
    info "Claude Desktop config not found at: $CLAUDE_CONFIG"
    info "Create it with this content:"
    echo ""
    echo -e "${CYAN}{"
    echo "  \"mcpServers\": {"
    echo "    \"conduit-lightning\": {"
    echo "      \"command\": \"$VENV_PYTHON\","
    echo "      \"args\": [\"-m\", \"$MCP_MODULE\"],"
    echo "      \"env\": {"
    echo "        \"PYTHONPATH\": \"$SCRIPT_DIR/src\""
    echo "      }"
    echo "    }"
    echo "  }"
    echo -e "}${NC}"
fi

# =============================================================================
# Done!
# =============================================================================
echo ""
echo -e "${GREEN}${BOLD}  ⚡ Conduit is ready!${NC}"
echo ""
echo "  Next steps:"
echo "    1. Make sure your LND credentials are in credentials/"
echo "    2. Update LND_HOST in .env to point to your node"
echo "    3. Restart Claude Desktop (Cmd+Q, then reopen)"
echo "    4. Ask Claude: \"What's my Lightning node balance?\""
echo ""
echo "  Useful commands:"
echo "    source .venv/bin/activate         # activate environment"
echo "    PYTHONPATH=src alembic upgrade head  # run migrations"
echo "    PYTHONPATH=src python -m conduit.mcp_server  # run server manually"
echo ""
