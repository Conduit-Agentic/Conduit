"""Shared test fixtures for Conduit tests.

Sets environment variables before any conduit module is imported,
preventing the database engine from trying to connect to PostgreSQL.
"""

import os
import sys
from unittest.mock import MagicMock

# Set test environment before importing any conduit modules
os.environ.setdefault("CONDUIT_API_KEY", "test-api-key-for-unit-tests")
os.environ.setdefault("DATABASE_URL", "postgresql+asyncpg://test:test@localhost:5432/test")
os.environ.setdefault("DEBUG", "false")

# Mock the database module so imports don't trigger engine creation
# when PostgreSQL isn't available (unit tests only)
if "conduit.core.database" not in sys.modules:
    mock_db = MagicMock()
    mock_db.async_session_factory = MagicMock()
    sys.modules["conduit.core.database"] = mock_db
