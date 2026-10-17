# Common printing functions for Omarchy scripts

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m' # No Color

# Message printing functions
print_info() {
  echo -e "${BLUE}==>${NC} $1"
}

print_success() {
  echo -e "${GREEN}✓${NC} $1"
}

print_error() {
  echo -e "${RED}✗${NC} $1"
}

print_warning() {
  echo -e "${YELLOW}⚠${NC} $1"
}

print_step() {
  echo -e "  ${BLUE}→${NC} $1"
}

print_header() {
  echo -e "${BOLD}================================${NC}"
  echo -e "${BOLD}$1${NC}"
  echo -e "${BOLD}================================${NC}"
}
