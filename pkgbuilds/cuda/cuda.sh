export CUDA_PATH=/opt/cuda
append_path '/opt/cuda/bin'
export PATH


# Set the default host compiler for nvcc. This will need to be switched back
# and forth between the latest and previous GCC version, whatever nvcc
# currently supports.
export NVCC_CCBIN='/usr/bin/g++'
