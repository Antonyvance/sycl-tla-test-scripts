#!/bin/bash
# Local test script replicating CI workflow for SYCL CUTLASS
# Based on .github/workflows/intel_test.yml

set -e  # Exit on error

# Color output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Function to print section headers
print_header() {
    echo -e "\n${GREEN}===================================================${NC}"
    echo -e "${GREEN}$1${NC}"
    echo -e "${GREEN}===================================================${NC}\n"
}

print_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

print_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

# Print usage information
usage() {
    echo "Usage: $0 [OPTIONS] [PR_NUMBER]"
    echo ""
    echo "Options:"
    echo "  -p, --pr PR_NUMBER     Checkout and test specific PR number"
    echo "  -b, --branch BRANCH    Checkout and test specific branch (default: main)"
    echo "  --gpu GPU              GPU type (BMG or PVC, default: BMG)"
    echo "  --sycl-target TARGET   SYCL target (default: intel_gpu_bmg_g21)"
    echo "  --repo-dir DIR         Repository directory path"
    echo "  --build-dir DIR        Build directory (default: REPO_DIR/build)"
    echo "  --jobs N               Parallel jobs (default: 8)"
    echo "  --skip-build           Skip build step"
    echo "  --skip-unit-tests      Skip unit tests"
    echo "  --skip-examples        Skip examples"
    echo "  --skip-benchmarks      Skip benchmarks"
    echo "  --clean                Clean build directory before building"
    echo "  -h, --help             Show this help message"
    echo ""
    echo "Examples:"
    echo "  $0                     # Test current repository state (no checkout)"
    echo "  $0 595                 # Test PR #595 (positional argument)"
    echo "  $0 -p 595              # Test PR #595 (explicit option)"
    echo "  $0 -b feature-branch   # Test specific branch"
    echo "  $0 --gpu PVC           # Test on PVC instead of BMG"
    echo ""
    echo "Repository behavior:"
    echo "  - No PR/branch specified: Uses existing repository state"
    echo "  - PR number provided: Checks out and tests that PR"
    echo "  - Branch provided: Checks out and tests that branch"
    echo ""
    echo "Dependencies:"
    echo "  - GitHub CLI (gh) for PR checkout functionality"
    echo "  - Intel oneAPI toolkit for SYCL compilation"
    echo "  - cmake, ninja-build for building"
}

# Parse command line arguments
PR_NUMBER=""
BRANCH="main"
REPO_URL="https://github.com/intel/sycl-tla.git"
POSITIONAL_ARGS=()

# Default values (can be overridden via command line)
GPU="${GPU:-BMG}"
SYCL_TARGET="${SYCL_TARGET:-intel_gpu_bmg_g21}"
IGC_VERSION_MAJOR="${IGC_VERSION_MAJOR:-2}"
IGC_VERSION_MINOR="${IGC_VERSION_MINOR:-18}"
REPO_DIR="${REPO_DIR:-/home/sycl-tla}"
BUILD_DIR="${BUILD_DIR:-${REPO_DIR}/build}"
PARALLEL_JOBS="${PARALLEL_JOBS:-8}"

while [[ $# -gt 0 ]]; do
  case $1 in
    -p|--pr)
      PR_NUMBER="$2"
      shift 2
      ;;
    -b|--branch)
      BRANCH="$2"
      shift 2
      ;;
    --gpu)
      GPU="$2"
      shift 2
      ;;
    --sycl-target)
      SYCL_TARGET="$2"
      shift 2
      ;;
    --repo-dir)
      REPO_DIR="$2"
      BUILD_DIR="${REPO_DIR}/build"  # Update build dir when repo dir changes
      shift 2
      ;;
    --build-dir)
      BUILD_DIR="$2"
      shift 2
      ;;
    --jobs)
      PARALLEL_JOBS="$2"
      shift 2
      ;;
    --skip-build)
      SKIP_BUILD=1
      shift
      ;;
    --skip-unit-tests)
      SKIP_UNIT_TESTS=1
      shift
      ;;
    --skip-examples)
      SKIP_EXAMPLES=1
      shift
      ;;
    --skip-benchmarks)
      SKIP_BENCHMARKS=1
      shift
      ;;
    --clean)
      CLEAN_BUILD=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    --*)
      print_error "Unknown option: $1"
      usage
      exit 1
      ;;
    *)
      # Check if it's a number (PR number)
      if [[ "$1" =~ ^[0-9]+$ ]]; then
        PR_NUMBER="$1"
      else
        POSITIONAL_ARGS+=("$1")
      fi
      shift
      ;;
  esac
done

# Restore positional parameters
set -- "${POSITIONAL_ARGS[@]}"

# Validate inputs
if [[ -n "$PR_NUMBER" && "$BRANCH" != "main" ]]; then
    print_error "Cannot specify both PR number and branch"
    exit 1
fi

# Set GPU-specific defaults
if [[ "$GPU" == "PVC" ]]; then
    SYCL_TARGET="${SYCL_TARGET:-intel_gpu_pvc}"
    IGC_VERSION_MAJOR="${IGC_VERSION_MAJOR:-2}"
    IGC_VERSION_MINOR="${IGC_VERSION_MINOR:-11}"
elif [[ "$GPU" == "BMG" ]]; then
    SYCL_TARGET="${SYCL_TARGET:-intel_gpu_bmg_g21}"
    IGC_VERSION_MAJOR="${IGC_VERSION_MAJOR:-2}"
    IGC_VERSION_MINOR="${IGC_VERSION_MINOR:-18}"
fi

# Function to setup repository
setup_repository() {
    print_info "Setting up repository..."
    
    # Check if repository directory exists
    if [[ ! -d "$REPO_DIR" ]]; then
        print_info "Repository directory not found. Cloning repository..."
        mkdir -p "$(dirname "$REPO_DIR")"
        git clone "$REPO_URL" "$REPO_DIR"
    fi
    
    # Navigate to repository
    cd "$REPO_DIR" || {
        print_error "Failed to navigate to repository directory: $REPO_DIR"
        exit 1
    }
    
    # Ensure we have a clean working directory
    print_info "Cleaning working directory..."
    git reset --hard HEAD
    git clean -fd
    
    # Fetch latest changes
    print_info "Fetching latest changes..."
    git fetch origin
    
    # Checkout appropriate branch/PR
    if [[ -n "$PR_NUMBER" ]]; then
        print_info "Checking out PR #$PR_NUMBER using GitHub CLI..."
        
        # First checkout main to ensure clean state
        git checkout main || git checkout -b main origin/main
        git reset --hard origin/main
        
        # Configure git to handle diverging branches
        git config advice.diverging false
        
        # Use gh pr checkout with force to handle conflicts
        gh pr checkout "$PR_NUMBER" --force || {
            print_error "Failed to checkout PR #$PR_NUMBER. Make sure 'gh' CLI is installed and authenticated."
            print_info "Trying alternative method..."
            
            # Alternative: manual PR checkout
            PR_BRANCH="pr-$PR_NUMBER"
            git fetch origin "pull/$PR_NUMBER/head:$PR_BRANCH" || {
                print_error "Failed to fetch PR #$PR_NUMBER"
                exit 1
            }
            git checkout "$PR_BRANCH" || {
                print_error "Failed to checkout PR branch $PR_BRANCH"
                exit 1
            }
        }
        print_success "Successfully checked out PR #$PR_NUMBER"
    else
        print_info "Checking out branch: $BRANCH..."
        git checkout "$BRANCH" || {
            print_error "Failed to checkout branch: $BRANCH"
            exit 1
        }
        git reset --hard "origin/$BRANCH" || {
            print_error "Failed to reset to origin/$BRANCH"
            exit 1
        }
        print_success "Successfully checked out branch: $BRANCH"
    fi
    
    # Show current commit info
    print_info "Current commit:"
    git log --oneline -1
}

# Function to print section headers
print_header() {
    echo -e "\n${GREEN}===================================================${NC}"
    echo -e "${GREEN}$1${NC}"
    echo -e "${GREEN}===================================================${NC}\n"
}

print_info() {
    echo -e "${YELLOW}[INFO]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

print_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

# Verify repository directory exists
if [ ! -d "$REPO_DIR" ]; then
    print_error "Repository directory not found: $REPO_DIR"
    exit 1
fi

cd "$REPO_DIR"

print_header "SYCL CUTLASS Local Test Run"

# Setup repository (checkout PR or branch if specified)
if [[ -n "$PR_NUMBER" ]] || [[ "$BRANCH" != "main" ]]; then
    setup_repository
elif [[ ! -d "$REPO_DIR" ]]; then
    print_error "Repository directory not found: $REPO_DIR"
    print_info "Either provide a PR number/branch or ensure repository exists at $REPO_DIR"
    exit 1
else
    print_info "Using existing repository state (no checkout performed)"
    # Still navigate to the repository directory
    cd "$REPO_DIR" || {
        print_error "Failed to navigate to repository directory: $REPO_DIR"
        exit 1
    }
    
    # Show current commit info for reference
    print_info "Current repository state:"
    git log --oneline -1 2>/dev/null || print_warning "Not a git repository or no commits found"
fi

print_info "GPU: $GPU"
print_info "SYCL Target: $SYCL_TARGET"
print_info "IGC Version: $IGC_VERSION_MAJOR.$IGC_VERSION_MINOR"
print_info "Repository: $REPO_DIR"
print_info "Build Directory: $BUILD_DIR"
print_info "Parallel Jobs: $PARALLEL_JOBS"

# Ensure we're in the repository directory
cd "$REPO_DIR"

# Setup environment
print_header "Setting up environment"

# Install required tools (matching CI)
print_info "Checking for required build tools..."
if ! command -v cmake &> /dev/null || ! command -v ninja &> /dev/null; then
    print_warning "Installing cmake and/or ninja..."
    sudo apt update
    sudo apt install -y cmake ninja-build
else
    print_info "cmake and ninja already available"
fi

# Install GitHub CLI if not available
if ! command -v gh &> /dev/null; then
    print_warning "Installing GitHub CLI..."
    sudo apt update
    sudo apt install -y gh
else
    print_info "GitHub CLI already available"
fi

# Source Intel oneAPI environment (matching CI setvars.sh call)
if [ -f "/opt/intel/oneapi/setvars.sh" ]; then
    print_info "Sourcing Intel oneAPI environment..."
    set +e  # Temporarily disable exit on error
    source /opt/intel/oneapi/setvars.sh > /dev/null 2>&1
    SETVARS_EXIT=$?
    set -e  # Re-enable exit on error
    
    if [ $SETVARS_EXIT -ne 0 ]; then
        print_warning "setvars.sh returned exit code $SETVARS_EXIT (usually safe to ignore)"
    fi
    print_success "Intel oneAPI environment loaded"
else
    print_error "Intel oneAPI environment not found at /opt/intel/oneapi/setvars.sh"
    print_info "Please install Intel oneAPI toolkit or adjust the path"
    exit 1
fi

# Set SYCL environment variables (exactly matching CI)
export IGC_ExtraOCLOptions="-cl-intel-256-GRF-per-thread"
export SYCL_PROGRAM_COMPILE_OPTIONS="-ze-opt-large-register-file -gline-tables-only"
export ONEAPI_DEVICE_SELECTOR=level_zero:gpu
export IGC_VectorAliasBBThreshold=100000000000

# Set compiler environment variables - CRITICAL for CMake
export CXX=icpx
export CC=icx

print_info "Environment variables set:"
print_info "  CXX=${CXX}"
print_info "  CC=${CC}"
print_info "  IGC_ExtraOCLOptions=${IGC_ExtraOCLOptions}"
print_info "  SYCL_PROGRAM_COMPILE_OPTIONS=${SYCL_PROGRAM_COMPILE_OPTIONS}"
print_info "  ONEAPI_DEVICE_SELECTOR=${ONEAPI_DEVICE_SELECTOR}"
print_info "  IGC_VectorAliasBBThreshold=${IGC_VectorAliasBBThreshold}"

# Verify tools (matching CI)
print_info "Verifying build tools..."
which ${CXX} || { print_error "CXX compiler not found"; exit 1; }
which cmake || { print_error "cmake not found"; exit 1; }
which ninja || { print_error "ninja not found"; exit 1; }

print_info "Compiler: $(${CXX} --version | head -1)"
print_info "CMake: $(cmake --version | head -1)"
print_info "Ninja: $(ninja --version)"

# List available SYCL devices (matching CI)
print_info "Available SYCL devices:"
sycl-ls || print_warning "sycl-ls failed (may not be critical)"

# Clean build if requested
if [ -n "$CLEAN_BUILD" ]; then
    print_header "Cleaning build directory"
    if [ -d "$BUILD_DIR" ]; then
        print_info "Removing $BUILD_DIR"
        rm -rf "$BUILD_DIR"
    fi
fi

# Create build directory
mkdir -p "$BUILD_DIR"
cd "$BUILD_DIR"

# Configure and build
if [ -z "$SKIP_BUILD" ]; then
    print_header "Configuring CMake"
    
    # Create/clean build directory
    if [ -d "$BUILD_DIR" ]; then
        print_warning "Build directory exists, cleaning..."
        rm -rf "$BUILD_DIR"
    fi
    mkdir -p "$BUILD_DIR"
    cd "$BUILD_DIR"
    
    # CMake configuration exactly matching CI
    cmake -G Ninja \
        -DCUTLASS_ENABLE_SYCL=ON \
        -DDPCPP_SYCL_TARGET="$SYCL_TARGET" \
        -DIGC_VERSION_MAJOR="$IGC_VERSION_MAJOR" \
        -DIGC_VERSION_MINOR="$IGC_VERSION_MINOR" \
        -DCUTLASS_SYCL_RUNNING_CI=ON \
        -DCMAKE_CXX_FLAGS="-Werror" \
        .. || { print_error "CMake configuration failed"; exit 1; }
    
    print_success "CMake configuration completed"
    
    print_header "Building project"
    print_info "Running: cmake --build ."
    
    # Build exactly matching CI (no parallel flag in CI)
    cmake --build . || { print_error "Build failed"; exit 1; }
    
    print_success "Build completed"
else
    print_info "Skipping build (--skip-build specified)"
    # Still need to be in build directory for subsequent commands
    if [ ! -d "$BUILD_DIR" ]; then
        print_error "Build directory does not exist and build is skipped. Run without --skip-build first."
        exit 1
    fi
    cd "$BUILD_DIR"
fi

# Run unit tests
if [ -z "$SKIP_UNIT_TESTS" ]; then
    print_header "Running unit tests"
    print_info "Running: cmake --build . --target test_unit -j 8"
    
    # Unit tests exactly matching CI (-j 8)
    cmake --build . --target test_unit -j 8 || { print_error "Unit tests failed"; exit 1; }
    
    print_success "Unit tests completed"
else
    print_info "Skipping unit tests (--skip-unit-tests specified)"
fi

# Run examples
if [ -z "$SKIP_EXAMPLES" ]; then
    print_header "Running examples"
    print_info "Running: cmake --build . --target test_examples -j 1"
    
    # Examples exactly matching CI (-j 1 to avoid device contention)
    cmake --build . --target test_examples -j 1 || { print_error "Examples failed"; exit 1; }
    
    print_success "Examples completed"
else
    print_info "Skipping examples (--skip-examples specified)"
fi

# Build benchmarks
if [ -z "$SKIP_BENCHMARKS" ]; then
    print_header "Building benchmarks"
    print_info "Running: cmake --build . --target cutlass_benchmarks"
    
    # Benchmarks exactly matching CI (no parallel flag)
    cmake --build . --target cutlass_benchmarks || { print_error "Benchmarks build failed"; exit 1; }
    
    print_success "Benchmarks built"
else
    print_info "Skipping benchmarks (--skip-benchmarks specified)"
fi

# Summary
print_header "Test Run Summary"
print_success "All requested tests completed successfully!"
print_info "Build directory: $BUILD_DIR"
print_info ""
print_info "To run individual targets:"
print_info "  cd $BUILD_DIR"
print_info "  ninja <target_name>"
print_info ""
print_info "To run specific tests:"
print_info "  cd $BUILD_DIR"
print_info "  ctest -R <test_pattern>"
print_info ""
print_info "Example - Run specific Intel Xe test:"
print_info "  cd $BUILD_DIR"
print_info "  ctest -R XE_Device_Gemm_fp16t_fp8n_f32t_tensor_op_f32_group_gemm"
print_info "  # Or run the executable directly:"
print_info "  ./test/unit/gemm/device/XE_Device_Gemm_fp16t_fp8n_f32t_tensor_op_f32_group_gemm"
