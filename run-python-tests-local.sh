#!/bin/bash
set -e

# Color output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

echo -e "${BLUE}========================================${NC}"
echo -e "${BLUE}CUTLASS Python Interface Test (Local)${NC}"
echo -e "${BLUE}========================================${NC}"

# Configuration
REPO_DIR="${REPO_DIR:-/home/sycl-tla}"
VENV_PATH="${VENV_PATH:-~/.venv/sycl-tla-test-new}"
PYTHON_VERSION="${PYTHON_VERSION:-3}"  # Use system python3

# Expand tilde to home directory
VENV_PATH=$(eval echo $VENV_PATH)

echo -e "${YELLOW}Configuration:${NC}"
echo "  Repository: $REPO_DIR"
echo "  Virtual environment: $VENV_PATH"
echo ""

# Check if repository exists
if [ ! -d "$REPO_DIR" ]; then
    echo -e "${RED}Error: Repository directory not found: $REPO_DIR${NC}"
    exit 1
fi

cd "$REPO_DIR"

# Step 1: Setup virtual environment with system Python
echo -e "${GREEN}[1/6] Setting up Python virtual environment...${NC}"

# Detect Python version
if command -v python${PYTHON_VERSION} &> /dev/null; then
    PYTHON_CMD="python${PYTHON_VERSION}"
    PYTHON_VER=$($PYTHON_CMD --version 2>&1 | awk '{print $2}')
    echo "Using system Python: $PYTHON_VER"
else
    echo -e "${RED}Error: python${PYTHON_VERSION} not found${NC}"
    exit 1
fi

if [ ! -d "$VENV_PATH" ]; then
    echo "Creating virtual environment at $VENV_PATH..."
    $PYTHON_CMD -m venv "$VENV_PATH"
    
    if [ $? -ne 0 ]; then
        echo -e "${YELLOW}Failed to create venv. Installing python3-venv...${NC}"
        sudo apt install -y python3-venv
        $PYTHON_CMD -m venv "$VENV_PATH"
        
        if [ $? -ne 0 ]; then
            echo -e "${RED}Error: Failed to create virtual environment${NC}"
            exit 1
        fi
    fi
    echo -e "${GREEN}Virtual environment created successfully${NC}"
else
    echo "Virtual environment already exists at $VENV_PATH"
fi

# Activate virtual environment
source "$VENV_PATH/bin/activate"

# Verify Python version
echo "Python version: $(python --version)"
echo ""

# Step 2: Source Intel oneAPI environment
echo -e "${GREEN}[2/6] Sourcing Intel oneAPI environment...${NC}"
if [ -f "/opt/intel/oneapi/setvars.sh" ]; then
    set +e
    source /opt/intel/oneapi/setvars.sh > /dev/null 2>&1
    SETVARS_EXIT=$?
    set -e
    if [ $SETVARS_EXIT -ne 0 ]; then
        echo -e "${YELLOW}Warning: setvars.sh returned exit code $SETVARS_EXIT (this is often normal)${NC}"
    fi
    echo "oneAPI environment sourced successfully"
else
    echo -e "${RED}Error: /opt/intel/oneapi/setvars.sh not found${NC}"
    exit 1
fi

# Check SYCL availability
echo "Checking SYCL devices:"
sycl-ls
echo ""

# Step 3: Install DPCTL (optional but recommended)
echo -e "${GREEN}[3/6] Installing DPCTL (optional, skip if fails)...${NC}"
set +e
if ! python -c "import dpctl" 2>/dev/null; then
    echo "DPCTL not found, attempting to install..."
    pip install dpctl
    if [ $? -ne 0 ]; then
        echo -e "${YELLOW}Warning: DPCTL installation failed, continuing anyway...${NC}"
    fi
else
    echo "DPCTL already installed"
fi
set -e
echo ""

# Step 4: Install Torch XPU (optional)
echo -e "${GREEN}[4/6] Installing PyTorch XPU (optional)...${NC}"
INSTALL_TORCH="${INSTALL_TORCH:-yes}"
if [ "$INSTALL_TORCH" = "yes" ]; then
    echo "Installing PyTorch with XPU support..."
    pip install torch torchvision torchaudio --index-url https://download.pytorch.org/whl/test/xpu
    # Uninstall conflicting packages
    pip uninstall --yes intel-sycl-rt intel-cmplr-lib-ur umf 2>/dev/null || true
else
    echo "Skipping PyTorch installation (set INSTALL_TORCH=yes to enable)"
fi
echo ""

# Step 5: Install CUTLASS Python interface
echo -e "${GREEN}[5/6] Installing CUTLASS Python interface...${NC}"
echo "Installing in editable mode from: $REPO_DIR"
pip install -e .
echo ""

# Step 6: Run Python tests
echo -e "${GREEN}[6/6] Running Python GEMM tests...${NC}"

# Set environment variables
export CUTLASS_USE_SYCL=1
export ONEAPI_DEVICE_SELECTOR=level_zero:gpu
# Optional: Enable SYCL tracing
# export SYCL_UR_TRACE=2

# Set IGC options
export IGC_ExtraOCLOptions="-cl-intel-256-GRF-per-thread"
export SYCL_PROGRAM_COMPILE_OPTIONS="-ze-opt-large-register-file -gline-tables-only"
export IGC_VectorAliasBBThreshold=100000000000

echo "Environment variables set:"
echo "  CUTLASS_USE_SYCL=$CUTLASS_USE_SYCL"
echo "  ONEAPI_DEVICE_SELECTOR=$ONEAPI_DEVICE_SELECTOR"
echo "  IGC_ExtraOCLOptions=$IGC_ExtraOCLOptions"
echo ""

# Run the test
TEST_FILE="${TEST_FILE:-test/python/cutlass/gemm/gemm_bf16_pvc.py}"
echo -e "${BLUE}Running test: $TEST_FILE${NC}"

if [ -f "$TEST_FILE" ]; then
    python "$TEST_FILE"
    TEST_EXIT=$?
    echo ""
    if [ $TEST_EXIT -eq 0 ]; then
        echo -e "${GREEN}========================================${NC}"
        echo -e "${GREEN}Python tests completed successfully!${NC}"
        echo -e "${GREEN}========================================${NC}"
    else
        echo -e "${RED}========================================${NC}"
        echo -e "${RED}Python tests failed with exit code $TEST_EXIT${NC}"
        echo -e "${RED}========================================${NC}"
        exit $TEST_EXIT
    fi
else
    echo -e "${RED}Error: Test file not found: $TEST_FILE${NC}"
    echo "Available test files:"
    find test/python/cutlass -name "*.py" -type f 2>/dev/null || echo "  (none found)"
    exit 1
fi

echo ""
echo -e "${BLUE}To run other tests, use:${NC}"
echo "  TEST_FILE=test/python/cutlass/gemm/your_test.py $0"
echo ""
echo -e "${BLUE}To deactivate virtual environment:${NC}"
echo "  deactivate"
