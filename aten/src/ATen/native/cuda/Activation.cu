#define _USE_MATH_DEFINES

#include <ATen/native/Activation.h>

#include <math.h>

#include <ATen/ATen.h>
#include <ATen/AccumulateType.h>
#include <ATen/Dispatch.h>
#include <ATen/NativeFunctions.h>
#include <ATen/core/Array.h>
#include <ATen/cuda/CUDAApplyUtils.cuh>
#include <ATen/cuda/detail/IndexUtils.cuh>
#include <ATen/cuda/detail/OffsetCalculator.cuh>
#include <ATen/native/cuda/Loops.cuh>
#include <c10/cuda/CUDAMathCompat.h>


namespace at { namespace native {

// -----------------------------------
// prelu forward
// -----------------------------------
template <typename scalar_t>
void prelu_cuda_kernel_share_weights(
  const Tensor& input,
  Tensor& result,
  const scalar_t* weight_data) {
  at::TensorIterator iter;
  iter.add_output(result);
  iter.add_input(input);
  iter.build();

  at::native::gpu_kernel(iter,
    [weight_data] GPU_LAMBDA (scalar_t input_val) {
        return (input_val > 0) ? input_val : *weight_data * input_val;
    });
}

template <typename scalar_t>
__global__ void prelu_cuda_kernel_multi_weights(
  scalar_t* result_data,
  const scalar_t* input_data,
  const scalar_t* weight_data,
  int64_t input_stride0,
  int64_t input_stride1,
  int64_t input_numel) {

  int64_t linearId = blockIdx.x * blockDim.x + threadIdx.x;
  if (linearId >= input_numel) return;

  // multiply values at each channel with weight[channel_index]
  int64_t channel = (linearId % input_stride0) / input_stride1;
  scalar_t input_data_val = input_data[linearId];
  result_data[linearId] = (input_data_val > 0) ? input_data_val : weight_data[channel] * input_data_val;
}

Tensor prelu_cuda(const Tensor& self, const Tensor& weight_) {
  TORCH_CHECK(self.is_cuda());
  TORCH_CHECK(weight_.is_cuda());

  auto input = self.contiguous();
  auto weight = weight_.contiguous();

  TORCH_CHECK(input.is_contiguous());
  TORCH_CHECK(weight.is_contiguous());

  int64_t weight_num = weight.numel();
  Tensor result = at::empty_like(input, LEGACY_CONTIGUOUS_MEMORY_FORMAT);
  auto strides = input.strides();

  // case1: shared weight for all channels
  if (weight_num == 1) {
    AT_DISPATCH_FLOATING_TYPES_AND(at::ScalarType::Half, input.scalar_type(), "prelu_cuda", [&] {
      prelu_cuda_kernel_share_weights<scalar_t>(
        input,
        result,
        weight.data_ptr<scalar_t>());
    });
  }
  else { // case2: multiple weights, one for each channel
    int64_t input_ndim = input.dim();
    TORCH_CHECK(input_ndim > 0, "Not allow zero-dim input tensor.");

    int64_t channel_size = 1; // channel_size default to 1
    int64_t input_stride0 = 1, input_stride1 = 1;

    if (input_ndim > 1) {
      channel_size = input.size(1); // channel is the 2nd dim of input
      input_stride0 = strides[0];
      input_stride1 = strides[1];
    }
    TORCH_CHECK(channel_size == weight_num,
      "Mismatch of parameter numbers and input channel size. Found parameter numbers = ", weight_num,
      " and channel size = ", channel_size, ".");

    // config to run cuda kernel
    int64_t input_numel = input.numel();
    const dim3 block = dim3(std::min(static_cast<int64_t>(cuda::getApplyBlock().x), input_numel));
    dim3 grid;
    int curDevice = -1;
    cudaGetDevice(&curDevice);
    cudaStream_t stream = at::cuda::getCurrentCUDAStream(curDevice);
    TORCH_CHECK(cuda::getApplyGrid(input_numel, grid, curDevice), "prelu: input too large or too many dimensions");

    AT_DISPATCH_FLOATING_TYPES_AND(at::ScalarType::Half, input.scalar_type(), "prelu_cuda", [&] {
      prelu_cuda_kernel_multi_weights<scalar_t>
      <<<grid, block, 0, stream>>>(
        result.data_ptr<scalar_t>(),
        input.data_ptr<scalar_t>(),
        weight.data_ptr<scalar_t>(),
        input_stride0,
        input_stride1,
        input_numel);
    });
  }
  return result;
}

// -----------------------------------
// prelu backward
// -----------------------------------
template<typename scalar_t, typename inp_offset_calc_t, typename out_offset_calc_t>
__global__ void prelu_cuda_backward_share_weights_kernel(
  int numel,
  const scalar_t *input_data,
  const scalar_t *grad_out_data,
  scalar_t *input_grad_data,
  scalar_t *weight_grad_collector_data,
  const scalar_t *weight_data,
  inp_offset_calc_t inp_calc,
  out_offset_calc_t out_calc
) {
  scalar_t inputs[THREAD_WORK_SIZE];
  scalar_t grad_outs[THREAD_WORK_SIZE];
  scalar_t weight = *weight_data;

  int base_index = BLOCK_WORK_SIZE * blockIdx.x;
  int remaining = std::min<int>(numel - base_index, BLOCK_WORK_SIZE);

  // load data into registers
  int thread_idx = threadIdx.x;
  #pragma unroll
  for(int i = 0; i < THREAD_WORK_SIZE; i++) {
    if (thread_idx >= remaining) {
      break;
    }
    int input_idx = thread_idx + base_index;
    auto offsets = inp_calc.get(input_idx);
    inputs[i] = input_data[offsets[0]];
    grad_outs[i] = grad_out_data[offsets[1]];
    thread_idx += num_threads;
  }

  // compute and store
  thread_idx = threadIdx.x;
  #pragma unroll
  for(int i = 0; i < THREAD_WORK_SIZE; i++) {
    if (thread_idx >= remaining) {
      break;
    }
    int input_idx = thread_idx + base_index;
    auto offsets = out_calc.get(input_idx);
    input_grad_data[offsets[0]] = (inputs[i] > 0) ? grad_outs[i] : weight * grad_outs[i];
    weight_grad_collector_data[offsets[1]] = (inputs[i] > 0) ? scalar_t(0) : inputs[i] * grad_outs[i];
    thread_idx += num_threads;
  }
}

template<typename scalar_t>
void launch_prelu_cuda_backward_share_weights_kernel(TensorIterator &iter, const scalar_t* weight_data) {
  if (!iter.can_use_32bit_indexing()) {
    for (auto& sub_iter : iter.with_32bit_indexing()) {
      launch_prelu_cuda_backward_share_weights_kernel(sub_iter, weight_data);
    }
    return;
  }

  int64_t numel = iter.numel();
  if (numel == 0) {
    return;
  }
  
  TORCH_INTERNAL_ASSERT_DEBUG_ONLY(iter.can_use_32bit_indexing());

  scalar_t *input_grad_data = static_cast<scalar_t *>(iter.data_ptr(0));
  scalar_t *weight_grad_collector_data = static_cast<scalar_t *>(iter.data_ptr(1));
  const scalar_t *input_data = static_cast<const scalar_t *>(iter.data_ptr(2));
  const scalar_t *grad_out_data = static_cast<const scalar_t *>(iter.data_ptr(3));

  int64_t grid = (numel + block_work_size - 1) / block_work_size;
  auto stream = at::cuda::getCurrentCUDAStream();

  TORCH_INTERNAL_ASSERT(iter.is_contiguous());
  prelu_cuda_backward_share_weights_kernel<scalar_t><<<grid, num_threads, 0, stream>>>(
    numel, input_data, grad_out_data, input_grad_data, weight_grad_collector_data, weight_data,
    TrivialOffsetCalculator<2>(), TrivialOffsetCalculator<2>()
  );
}

template <typename scalar_t>
void prelu_cuda_backward_kernel_share_weights(
  const Tensor& input,
  const Tensor& grad_out,
  Tensor& input_grad,
  Tensor& weight_grad_collector,
  const scalar_t* weight_data) {
  at::TensorIterator iter;
  iter.add_output(input_grad);
  iter.add_output(weight_grad_collector);
  iter.add_input(input);
  iter.add_input(grad_out);
  iter.build();
  launch_prelu_cuda_backward_share_weights_kernel(iter, weight_data);
}

template <typename scalar_t>
__global__ void prelu_cuda_backward_kernel_multi_weights(
  const scalar_t* input_data,
  const scalar_t* weight_data,
  const scalar_t* grad_out_data,
  scalar_t* input_grad_data,
  scalar_t* weight_grad_collector,
  int64_t input_stride0,
  int64_t input_stride1,
  int64_t input_numel) {

  int64_t linearId = blockIdx.x * blockDim.x + threadIdx.x;
  if (linearId >= input_numel) return;
  int64_t channel = (linearId % input_stride0) / input_stride1;
  scalar_t input_data_val = input_data[linearId];
  scalar_t grad_out_data_val = grad_out_data[linearId];
  input_grad_data[linearId] = (input_data_val > 0) ? grad_out_data_val : weight_data[channel] * grad_out_data_val;
  weight_grad_collector[linearId] = (input_data_val > 0) ? scalar_t(0) : input_data_val * grad_out_data_val;
}

std::tuple<Tensor, Tensor> prelu_backward_cuda(const Tensor& grad_out_, const Tensor& self, const Tensor& weight_) {
  TORCH_CHECK(grad_out_.is_cuda());
  TORCH_CHECK(self.is_cuda());
  TORCH_CHECK(weight_.is_cuda());

  auto input = self.contiguous();
  auto grad_out = grad_out_.contiguous();
  auto weight = weight_.contiguous();

  TORCH_CHECK(input.is_contiguous());
  TORCH_CHECK(weight.is_contiguous());
  TORCH_CHECK(grad_out.is_contiguous());

  int64_t weight_num = weight.numel();
  auto strides = input.strides();
  auto dims = input.dim();
  Tensor input_grad = at::empty_like(input, LEGACY_CONTIGUOUS_MEMORY_FORMAT);
  Tensor weight_grad = at::empty_like(weight, LEGACY_CONTIGUOUS_MEMORY_FORMAT);
  Tensor weight_grad_collector = at::empty_like(input, LEGACY_CONTIGUOUS_MEMORY_FORMAT);
  // case1: shared parameter for all channels
  if (weight_num == 1) {
    AT_DISPATCH_FLOATING_TYPES_AND(at::ScalarType::Half, input.scalar_type(), "prelu_backward_cuda", [&] {
      prelu_cuda_backward_kernel_share_weights<scalar_t>(
        input,
        grad_out,
        input_grad,
        weight_grad_collector,
        weight.data_ptr<scalar_t>());
    });
    weight_grad.fill_(weight_grad_collector.sum());
  }
  else { // case2: multiple parameters, one for each channel
    int64_t input_ndim = input.dim();
    TORCH_CHECK(input_ndim > 0, "Not allow zero-dim input tensor.");

    int64_t channel_size = 1; // channel_size default to 1
    int64_t input_stride0 = 1, input_stride1 = 1;

    if (input_ndim > 1) {
      channel_size = input.size(1); // channel is the 2nd dim of input
      input_stride0 = strides[0];
      input_stride1 = strides[1];
    }
    TORCH_CHECK(channel_size == weight_num,
      "Mismatch of parameter numbers and input channel size. Found parameter numbers = ", weight_num,
      " and channel size = ", channel_size, ".");

    // config to run cuda kernel
    int64_t input_numel = input.numel();
    const dim3 block = dim3(std::min(static_cast<int64_t>(cuda::getApplyBlock().x), input_numel));
    dim3 grid;
    int curDevice = -1;
    cudaGetDevice(&curDevice);
    cudaStream_t stream = at::cuda::getCurrentCUDAStream(curDevice);
    TORCH_CHECK(cuda::getApplyGrid(input_numel, grid, curDevice), "prelu_backward_cuda: input too large or too many dimensions");

    AT_DISPATCH_FLOATING_TYPES_AND(at::ScalarType::Half, input.scalar_type(), "prelu_backward_cuda", [&] {
      prelu_cuda_backward_kernel_multi_weights<scalar_t>
      <<<grid, block, 0, stream>>>(
        input.data_ptr<scalar_t>(),
        weight.data_ptr<scalar_t>(),
        grad_out.data_ptr<scalar_t>(),
        input_grad.data_ptr<scalar_t>(),
        weight_grad_collector.data_ptr<scalar_t>(),
        input_stride0,
        input_stride1,
        input_numel);
    });
    // update weight_grad
    std::vector<int64_t> reduce_dims;
    reduce_dims.push_back(0);
    if (dims > 2) {
      for(int64_t i = 2; i < dims; i++) reduce_dims.push_back(i);
    }
    weight_grad = weight_grad_collector.sum(reduce_dims);
  }
  return std::tuple<Tensor, Tensor>{input_grad, weight_grad};
}

// -----------------------------------
// hardshrink
// -----------------------------------
void hardshrink_kernel(TensorIterator& iter, Scalar value) {
  AT_DISPATCH_FLOATING_TYPES_AND2(at::ScalarType::Half, at::ScalarType::BFloat16, iter.dtype(), "hardshrink_cuda", [&]() {
    AT_SKIP_BFLOAT16_IF_NOT_ROCM(scalar_t, "hardshrink_cuda", [&] {
      auto lambd = value.to<scalar_t>();
      gpu_kernel(iter, [lambd]GPU_LAMBDA(scalar_t a) -> scalar_t {
        return (a >= -lambd && a <= lambd) ? scalar_t(0) : a;
      });
    });
  });
}

void softshrink_kernel(TensorIterator& iter, Scalar value) {
  AT_DISPATCH_FLOATING_TYPES_AND2(at::ScalarType::Half, at::ScalarType::BFloat16, iter.dtype(), "softshrink_cuda", [&]() {
    AT_SKIP_BFLOAT16_IF_NOT_ROCM(scalar_t, "softshrink_cuda", [&] {
      auto lambd = value.to<scalar_t>();
      gpu_kernel(iter, [lambd]GPU_LAMBDA(scalar_t a) -> scalar_t {
        return a > lambd ? a - lambd : (a < -lambd ? a + lambd : scalar_t(0));
      });
    });
  });
}

void shrink_backward_kernel(TensorIterator& iter, Scalar value) {
  AT_DISPATCH_FLOATING_TYPES_AND2(at::ScalarType::Half, at::ScalarType::BFloat16, iter.dtype(), "shrink_backward_cuda", [&]() {
    AT_SKIP_BFLOAT16_IF_NOT_ROCM(scalar_t, "shrink_backward_cuda", [&] {
      auto lambd = value.to<scalar_t>();
      gpu_kernel(iter, [lambd]GPU_LAMBDA(scalar_t grad_val, scalar_t self_val) -> scalar_t {
        return (self_val >= -lambd && self_val <= lambd) ? scalar_t(0) : grad_val;
      });
    });
  });
}

void hardtanh_backward_kernel(TensorIterator& iter, Scalar min, Scalar max) {
  AT_DISPATCH_FLOATING_TYPES_AND(at::ScalarType::Half, iter.dtype(), "hardtanh_backward_cuda", [&]() {
    auto min_val = min.to<scalar_t>();
    auto max_val = max.to<scalar_t>();
    gpu_kernel(iter, [min_val, max_val]GPU_LAMBDA(scalar_t a, scalar_t b) -> scalar_t {
      return (b <= min_val) || (b >= max_val) ? scalar_t(0) : a;
    });
  });
}

void softplus_kernel(TensorIterator& iter, Scalar beta_, Scalar threshold_) {
  AT_DISPATCH_FLOATING_TYPES_AND2(at::ScalarType::Half, at::ScalarType::BFloat16, iter.dtype(), "softplus_cuda", [&]() {
    AT_SKIP_BFLOAT16_IF_NOT_ROCM(scalar_t, "softplus_cuda", [&] {
      auto beta = beta_.to<scalar_t>();
      auto threshold = threshold_.to<scalar_t>();
      gpu_kernel(iter, [beta, threshold]GPU_LAMBDA(scalar_t a) -> scalar_t {
        return (a * beta) > threshold ? a : static_cast<scalar_t>(::log1p(std::exp(a * beta))) / beta;
      });
    });
  });
}

void softplus_backward_kernel(TensorIterator& iter, Scalar beta_, Scalar threshold_) {
  AT_DISPATCH_FLOATING_TYPES_AND2(at::ScalarType::Half, at::ScalarType::BFloat16, iter.dtype(), "softplus_backward_cuda", [&]() {
    AT_SKIP_BFLOAT16_IF_NOT_ROCM(scalar_t, "softplus_backward_cuda", [&] {
      auto beta = beta_.to<scalar_t>();
      auto threshold = threshold_.to<scalar_t>();
      gpu_kernel(iter, [beta, threshold]GPU_LAMBDA(scalar_t a, scalar_t b) -> scalar_t {
        scalar_t z = std::exp(b * beta);
        return (b * beta) > threshold ? a : a * (z - scalar_t(1.)) / z;
      });
    });
  });
}

template <typename scalar_t>
void threshold_kernel_impl(TensorIterator& iter, scalar_t threshold, scalar_t value) {
  gpu_kernel_with_scalars(iter, [=]GPU_LAMBDA(scalar_t x, scalar_t other) -> scalar_t {
    return x <= threshold ? value : other;
  });
}

static void threshold_kernel(TensorIterator& iter, Scalar threshold, Scalar value) {
  AT_DISPATCH_ALL_TYPES_AND2(at::ScalarType::Half, at::ScalarType::BFloat16, iter.dtype(), "threshold_cuda", [&] {
    AT_SKIP_BFLOAT16_IF_NOT_ROCM(scalar_t, "threshold_cuda", [&] {
      threshold_kernel_impl<scalar_t>(iter, threshold.to<scalar_t>(), value.to<scalar_t>());
    });
  });
}

void elu_kernel(TensorIterator& iter, Scalar alpha, Scalar scale, Scalar input_scale) {
  AT_DISPATCH_FLOATING_TYPES_AND2(at::ScalarType::Half, at::ScalarType::BFloat16, iter.dtype(), "elu_cuda", [&]() {
    AT_SKIP_BFLOAT16_IF_NOT_ROCM(scalar_t, "elu_cuda", [&] {
      auto negcoef = alpha.to<scalar_t>() * scale.to<scalar_t>();
      auto poscoef = scale.to<scalar_t>();
      auto negiptcoef = input_scale.to<scalar_t>();
      gpu_kernel(iter, [negcoef, poscoef, negiptcoef]GPU_LAMBDA(scalar_t a) -> scalar_t {
        return a > scalar_t(0) ? a * poscoef : (static_cast<scalar_t>(std::exp(a * negiptcoef)) - scalar_t(1.)) * negcoef;
      });
    });
  });
}

void elu_backward_kernel(TensorIterator& iter, Scalar alpha, Scalar scale, Scalar input_scale) {
  AT_DISPATCH_FLOATING_TYPES_AND2(at::ScalarType::Half, at::ScalarType::BFloat16, iter.dtype(), "elu_backward_cuda", [&]() {
    AT_SKIP_BFLOAT16_IF_NOT_ROCM(scalar_t, "elu_backward_cuda", [&] {
      auto negcoef = alpha.to<scalar_t>() * scale.to<scalar_t>();
      auto poscoef = scale.to<scalar_t>();
      auto negiptcoef = input_scale.to<scalar_t>();
      gpu_kernel(iter, [negcoef, poscoef, negiptcoef]GPU_LAMBDA(scalar_t a, scalar_t b) -> scalar_t {
        return b <= scalar_t(0) ? a * negiptcoef * (b + negcoef) : a * poscoef;
      });
    });
  });
}

namespace {

void GeluCUDAKernelImpl(TensorIterator& it) {
  AT_DISPATCH_FLOATING_TYPES_AND2(at::ScalarType::Half, at::ScalarType::BFloat16, it.dtype(), "GeluCUDAKernelImpl", [&]() {
    AT_SKIP_BFLOAT16_IF_NOT_ROCM(scalar_t, "GeluCUDAKernelImpl", [&] {
      using T_ACC = acc_type<scalar_t, true>;
      gpu_kernel(it, [] GPU_LAMBDA(scalar_t x) -> scalar_t {
        return static_cast<T_ACC>(x) *
            c10::cuda::compat::normcdf(static_cast<T_ACC>(x));
      });
    });
  });
}

void GeluBackwardCUDAKernelImpl(TensorIterator& it) {
  AT_DISPATCH_FLOATING_TYPES_AND2(at::ScalarType::Half, at::ScalarType::BFloat16,
      it.dtype(), "GeluBackwardCUDAKernelImpl", [&]() {
        AT_SKIP_BFLOAT16_IF_NOT_ROCM(scalar_t, "GeluBackwardCUDAKernelImpl", [&] {
          using T_ACC = acc_type<scalar_t, true>;
          gpu_kernel(it, [] GPU_LAMBDA(scalar_t dy, scalar_t x) -> scalar_t {
            constexpr T_ACC kBeta = M_2_SQRTPI * M_SQRT1_2 * T_ACC(0.5);
            const T_ACC cdf = c10::cuda::compat::normcdf(static_cast<T_ACC>(x));
            const T_ACC pdf =
                c10::cuda::compat::exp(
                    T_ACC(-0.5) * static_cast<T_ACC>(x) * static_cast<T_ACC>(x)) *
                kBeta;
            return static_cast<T_ACC>(dy) * (cdf + static_cast<T_ACC>(x) * pdf);
          });
        });
      });
}

void leaky_relu_kernel(TensorIterator& iter, Scalar negval_) {
  AT_DISPATCH_FLOATING_TYPES_AND2(at::ScalarType::Half, at::ScalarType::BFloat16, iter.dtype(), "leaky_relu_cuda", [&]() {
    AT_SKIP_BFLOAT16_IF_NOT_ROCM(scalar_t, "leaky_relu_cuda", [&] {
      auto negval = negval_.to<scalar_t>();
      gpu_kernel(iter, [negval]GPU_LAMBDA(scalar_t a) -> scalar_t {
        return a > scalar_t(0) ? a : a * negval;
      });
    });
  });
}

void leaky_relu_backward_kernel(TensorIterator& iter, Scalar negval_) {
  AT_DISPATCH_FLOATING_TYPES_AND2(at::ScalarType::Half, at::ScalarType::BFloat16, iter.dtype(), "leaky_relu_backward_cuda", [&]() {
    AT_SKIP_BFLOAT16_IF_NOT_ROCM(scalar_t, "leaky_relu_backward_cuda", [&] {
      auto negval = negval_.to<scalar_t>();
      gpu_kernel(iter, [negval]GPU_LAMBDA(scalar_t a, scalar_t b) -> scalar_t {
        return a > scalar_t(0) ? b : b * negval;
      });
    });
  });
}

void hardswish_kernel(TensorIterator& iter) {
  AT_DISPATCH_FLOATING_TYPES_AND2(at::ScalarType::Half, at::ScalarType::BFloat16, iter.dtype(), "hardswish_cuda", [&]() {
    AT_SKIP_BFLOAT16_IF_NOT_ROCM(scalar_t, "hardswish_cuda", [&] {
      const scalar_t zero(0.0f);
      const scalar_t one_sixth(1.0f / 6.0f);
      const scalar_t three(3.0f);
      const scalar_t six(6.0f);
      gpu_kernel(iter, [zero, one_sixth, three, six]GPU_LAMBDA(scalar_t self_val) -> scalar_t {
        return self_val * std::min(std::max(self_val + three, zero), six) * one_sixth;
      });
    });
  });
}

void hardswish_backward_kernel(TensorIterator& iter) {
  AT_DISPATCH_FLOATING_TYPES_AND2(at::ScalarType::Half, at::ScalarType::BFloat16, iter.dtype(), "hardswish_backward_cuda", [&]() {
    AT_SKIP_BFLOAT16_IF_NOT_ROCM(scalar_t, "hardswish_backward_cuda", [&] {
      const scalar_t zero(0.0f);
      const scalar_t three(3.0f);
      const scalar_t neg_three(-3.0f);
      const scalar_t one_half(0.5f);
      gpu_kernel(
        iter, 
        [zero, three, neg_three, one_half]GPU_LAMBDA(scalar_t grad_val, scalar_t self_val) -> scalar_t {
          if (self_val < neg_three) {
            return zero;
          } else if (self_val <= three) {
            return grad_val * ((self_val / three) + one_half);
          } else {
            return grad_val;
          }
      });
    });
  });
}

void hardsigmoid_kernel(TensorIterator& iter) {
  AT_DISPATCH_FLOATING_TYPES_AND2(at::ScalarType::Half, at::ScalarType::BFloat16, iter.dtype(), "hardsigmoid_cuda", [&]() {
    AT_SKIP_BFLOAT16_IF_NOT_ROCM(scalar_t, "hardsigmoid_cuda", [&] {
      const scalar_t zero(0.0f);
      const scalar_t one_sixth(1.0f / 6.0f);
      const scalar_t three(3.0f);
      const scalar_t six(6.0f);
      gpu_kernel(iter, [zero, one_sixth, three, six]GPU_LAMBDA(scalar_t self_val) -> scalar_t {
        return std::min(std::max(self_val + three, zero), six) * one_sixth;
      });
    });
  });
}

void hardsigmoid_backward_kernel(TensorIterator& iter) {
  AT_DISPATCH_FLOATING_TYPES_AND2(at::ScalarType::Half, at::ScalarType::BFloat16, iter.dtype(), "hardsigmoid_backward_cuda", [&]() {
    AT_SKIP_BFLOAT16_IF_NOT_ROCM(scalar_t, "hardsigmoid_backward_cuda", [&] {
      const scalar_t zero(0.0f);
      const scalar_t three(3.0f);
      const scalar_t neg_three(-3.0f);
      const scalar_t one_sixth(1.0f / 6.0f);
      gpu_kernel(
        iter, 
        [zero, three, neg_three, one_sixth]GPU_LAMBDA(scalar_t grad_val, scalar_t self_val) -> scalar_t {
          return (self_val >= neg_three && self_val <= three)
            ? grad_val * one_sixth
            : zero;
      });
    });
  });
}

} // namespace

Tensor gelu_cuda(const Tensor& self) {
  Tensor Y = at::native::empty_like(self, LEGACY_CONTIGUOUS_MEMORY_FORMAT);
  auto it = TensorIterator::unary_op(Y, self);
  GeluCUDAKernelImpl(it);
  return Y;
}

Tensor gelu_backward_cuda(const Tensor& grad, const Tensor& self) {
  Tensor dX = at::native::empty_like(self, LEGACY_CONTIGUOUS_MEMORY_FORMAT);
  auto it = TensorIterator::binary_op(dX, grad, self);
  GeluBackwardCUDAKernelImpl(it);
  return dX;
}

// computes `result = self <= threshold ? value : other`
// other is `self` in threshold() and `grad` in threshold_backward()
static Tensor threshold_out_cuda(
    optional<Tensor> opt_result,
    const Tensor& self,
    Scalar threshold,
    Scalar value,
    const Tensor& other) {
  Tensor result = opt_result.value_or(Tensor());
  auto iter = TensorIterator::binary_op(result, self, other);
  threshold_kernel(iter, threshold, value);
  return iter.output();
}

Tensor threshold_cuda(const Tensor& self, Scalar threshold, Scalar value) {
  return threshold_out_cuda(nullopt, self, threshold, value, self);
}

Tensor& threshold__cuda(Tensor& self, Scalar threshold, Scalar value) {
  threshold_out_cuda(make_optional(self), self, threshold, value, self);
  return self;
}

Tensor& threshold_out_cuda(Tensor& result, const Tensor& self, Scalar threshold, Scalar value) {
  threshold_out_cuda(make_optional(result), self, threshold, value, self);
  return result;
}

Tensor threshold_backward_cuda(const Tensor& grad, const Tensor& self, Scalar threshold) {
  return threshold_out_cuda(nullopt, self, threshold, 0, grad);
}

REGISTER_DISPATCH(hardtanh_backward_stub, &hardtanh_backward_kernel);
REGISTER_DISPATCH(hardshrink_stub, &hardshrink_kernel);
REGISTER_DISPATCH(softshrink_stub, &softshrink_kernel);
REGISTER_DISPATCH(shrink_backward_stub, &shrink_backward_kernel);
REGISTER_DISPATCH(elu_stub, &elu_kernel);
REGISTER_DISPATCH(elu_backward_stub, &elu_backward_kernel);
REGISTER_DISPATCH(leaky_relu_stub, &leaky_relu_kernel);
REGISTER_DISPATCH(leaky_relu_backward_stub, &leaky_relu_backward_kernel);
REGISTER_DISPATCH(hardswish_stub, &hardswish_kernel);
REGISTER_DISPATCH(hardswish_backward_stub, &hardswish_backward_kernel);
REGISTER_DISPATCH(hardsigmoid_stub, &hardsigmoid_kernel);
REGISTER_DISPATCH(hardsigmoid_backward_stub, &hardsigmoid_backward_kernel);
REGISTER_DISPATCH(softplus_stub, &softplus_kernel);
REGISTER_DISPATCH(softplus_backward_stub, &softplus_backward_kernel);

}}  // namespace at::native
