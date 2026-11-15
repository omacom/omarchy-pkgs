set --export --global CUDA_PATH /opt/cuda
fish_add_path --append --global /opt/cuda/bin

# Set the default host compiler for nvcc. This will need to be switched back
# and forth between the latest and previous GCC version, whatever nvcc
# currently supports.
set --export --global NVCC_CCBIN /usr/bin/g++
