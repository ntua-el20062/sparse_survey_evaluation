#include "HC-SpMM_kernel_v2.h"

#include <cuda.h>
#include <cuda_runtime.h>
#include <fstream>
#include <mma.h>
#include <sstream>
#include <stdio.h>
#include <thrust/device_vector.h>
#include <thrust/host_vector.h>
#include <thrust/sort.h>
#include <thrust/unique.h>
#include <torch/extension.h>
#include <torch/torch.h>
#include <vector>
using namespace nvcuda;

//////////////////////////////////////////////////////////////////////
// God knows why the fuck this is needed... I don't even want to bother explaining this shit.
namespace c10 {
	namespace detail {

		// Dummy for torchInternalAssertFail
		void __attribute__((weak)) torchInternalAssertFail(const char* expr, const char* file, unsigned int line, const char* function, const std::string& message)
		{
			printf("[Dummy torchInternalAssertFail] %s at %s:%u (%s): %s\n", expr, file, line, function, message.c_str());
			std::abort();  // <--- force it to not return
		}

		// Dummy for torchCheckFail
		void __attribute__((weak)) torchCheckFail(const char* expr, const char* file, unsigned int line, const std::string& message)
		{
			printf("[Dummy torchCheckFail] %s at %s:%u: %s\n", expr, file, line, message.c_str());
			std::abort();  // <--- force it to not return
		}

	} // namespace detail
} // namespace c10
//////////////////////////////////////////////////////////////////////

//////////////////////////////////////////////////////////////////////
/// Preprocessing
//////////////////////////////////////////////////////////////////////

__device__ __forceinline__ void inplace_deduplication_gpu(int *array, int length, int *loc)
{
	int cur = 1;
	while (cur < length) {
		if (array[cur] != array[cur - 1]) {
			(*loc)++;
			array[(*loc)] = array[cur];
		}
		cur++;
	}
}
__device__ __forceinline__ int binarysearch(int *arr, int size, int target)
{
	int left = 0;
	int right = size - 1;
	while (left <= right) {
		int mid = left + (right - left) / 2;
		if (arr[mid] == target) {
			while (mid > 0 && arr[mid - 1] == target) {
				mid--;
			}
			return mid;
		} else if (arr[mid] < target) {
			left = mid + 1;
		} else {
			right = mid - 1;
		}
	}
	return -1;
}
__global__ void generate_edgetocolumn(int *nodePointer, int *edgelist, int *edgelist_sort, int *edgetocol, int *blockpartition, int *blocknum, int blockSize_h, int blockSize_w, int num_nodes, int* hybrid_type) 
{
	int winId = blockIdx.x; // each warp one window
	unsigned block_start = nodePointer[winId * blockSize_h];
	unsigned block_end =
		nodePointer[min(winId * blockSize_h + blockSize_h, num_nodes)];
	unsigned num_window_edges = block_end - block_start;
	if (num_window_edges == 0)
		return;
	const unsigned threadPerBlock = blockDim.x * blockDim.y;
	int *start = edgelist_sort + block_start;
	int size = 0;
	inplace_deduplication_gpu(start, num_window_edges, &size);
	int num = (size + blockSize_w) / blockSize_w;
	atomicAdd(blocknum, num);
	blockpartition[winId] = num;
	//   hybrid_type[winId] = (size > 32 || (float)size * 0.19854024 - ((float)num_window_edges / (num * 16 * 8)) * 6.578043 - 3.14922857 > 0) ? 0:1;
	hybrid_type[winId] = (float)size * 0.19854024 - ((float)num_window_edges / (num * 16 * 8)) * 6.578043 - 3.14922857 ? 0:1;
	//   hybrid_type[winId] = 1; 
	for (unsigned idx = block_start; idx < block_end; idx += 1) {
		int index = binarysearch(start, size + 1, edgelist[idx]);
		edgetocol[idx] = index;
		if(index / BLK_W == 536870911) printf("Find %d\n", idx);
	}
}
void generate_edgetocolumn_cuda(int *nodePointer, int *edgelist, int *edgelist_sort, int *edgetocol, int *blockpartition, int *blocknum, int blockSize_h, int blockSize_w, int num_nodes, int* hybrid_type)
{
	int block_size = 1;
	int window_count = (num_nodes + blockSize_h - 1) / blockSize_h;
	int block_size1 = 128;
	int block_count1 = (window_count + 127) / 128;
	generate_edgetocolumn<<<window_count, block_size>>>(
			nodePointer, edgelist, edgelist_sort, edgetocol, blockpartition, blocknum,
			blockSize_h, blockSize_w, num_nodes, hybrid_type);

	//   cudaError_t error = cudaGetLastError();
	//   if (error != cudaSuccess) {
	//     printf("CUDA error: %s\n", cudaGetErrorString(error));
	//     exit(-1);
	//   }
}
__global__ void fill_segment(int *nodePointer, int *seg_out, int blockSize_h, int blockSize_w, int num_nodes)
{
	int tid = threadIdx.x;
	int winId = blockIdx.x; 
	unsigned block_start = nodePointer[winId * blockSize_h];
	unsigned block_end =
		nodePointer[min(winId * blockSize_h + blockSize_h, num_nodes)];
	unsigned num_window_edges = block_end - block_start;
	const unsigned threadPerBlock = blockDim.x * blockDim.y;
	for (unsigned idx = tid; idx < num_window_edges; idx += threadPerBlock) {
		seg_out[block_start + idx] = winId;
	}
}
void fill_segment_cuda(int *nodePointer, int *seg_out, int blockSize_h, int blockSize_w, int num_nodes)
{
	int block_size = 512;
	int window_count = (num_nodes + blockSize_h - 1) / blockSize_h;
	fill_segment<<<window_count, block_size>>>(nodePointer, seg_out, blockSize_h,
			blockSize_w, num_nodes);
	//   cudaError_t error = cudaGetLastError();
	//   if (error != cudaSuccess) {
	//     printf("CUDA error: %s\n", cudaGetErrorString(error));
	//     exit(-1);
	//   }
}
__global__ void fill_edgeToRow(int *edgeToRow, int *nodePointer, int num_nodes)
{
	int tid = blockDim.x * blockIdx.x + threadIdx.x;
	int nid = tid / 32;
	int laneid = tid % 32;
	if (nid < num_nodes) {
		#pragma unroll
		for (int eid = nodePointer[nid] + laneid; eid < nodePointer[nid + 1];
				eid += 32) {
			edgeToRow[eid] = nid;
		}
	}
}
void fill_edgeToRow_cuda(int *edgeToRow, int *nodePointer, int num_nodes)
{
	int wrap_size = 32;
	int block_size = 1024;
	int grid_size = (num_nodes * wrap_size + block_size - 1) / block_size;
	fill_edgeToRow<<<grid_size, block_size>>>(edgeToRow, nodePointer, num_nodes);
	//   cudaError_t error = cudaGetLastError();
	//   if (error != cudaSuccess) {
	//     printf("CUDA error: %s\n", cudaGetErrorString(error));
	//     exit(-1);
	//   }
}


// std::vector<torch::Tensor>
std::tuple<torch::Tensor, torch::Tensor, torch::Tensor, torch::Tensor, torch::Tensor, torch::Tensor>
preprocess(torch::Tensor edgeList_tensor, torch::Tensor nodePointer_tensor, int num_nodes, int edge_num, int rw_num)
{
	torch::Tensor blockPartition_tensor; 
	torch::Tensor edgeToColumn_tensor;
	torch::Tensor edgeToRow_tensor;
	torch::Tensor hybrid_type_tensor;

	auto d_edgeList = edgeList_tensor.data_ptr<int>();
	auto d_nodePointer = nodePointer_tensor.data_ptr<int>();

	int* d_blockPartition, * d_edgeToColumn, * d_edgeToRow, * d_hybrid_type;

	cudaMalloc((void**)&d_blockPartition, sizeof(int) * rw_num);
	cudaMemset(d_blockPartition, 0, rw_num);

	cudaMalloc((void**)&d_edgeToColumn, sizeof(int) * edge_num);
	cudaMemset(d_edgeToColumn, 0, edge_num);

	cudaMalloc((void**)&d_edgeToRow, sizeof(int) * edge_num);
	cudaMemset(d_edgeToRow, 0, edge_num);

	cudaMalloc((void**)&d_hybrid_type, sizeof(int) * rw_num);
	cudaMemset(d_hybrid_type, 0, rw_num);

	auto opts = torch::TensorOptions().dtype(torch::kInt).device(torch::kCUDA);
	blockPartition_tensor = torch::from_blob(d_blockPartition, {rw_num}, opts);
	edgeToColumn_tensor = torch::from_blob(d_edgeToColumn, {edge_num}, opts);
	edgeToRow_tensor = torch::from_blob(d_edgeToRow, {edge_num}, opts);
	hybrid_type_tensor = torch::from_blob(d_hybrid_type, {rw_num}, opts);

	int *seg_out, *block_num;

	cudaMalloc((void**)&seg_out, sizeof(int) * edge_num);
	cudaMemset(seg_out, 0, edge_num);

	cudaMalloc((void**)&block_num, sizeof(int) * 1);
	cudaMemset(block_num, 0, 1);

	fill_edgeToRow_cuda(d_edgeToRow, d_nodePointer, num_nodes);
	int block_counter = 0;
	fill_segment_cuda(d_nodePointer, seg_out, BLK_H, BLK_W, num_nodes);

	thrust::device_ptr<int> Seg = thrust::device_pointer_cast(seg_out);

	thrust::device_vector<int> deviceSeg(Seg, Seg + edge_num);

	thrust::device_ptr<int> EL = thrust::device_pointer_cast(d_edgeList);

	thrust::device_vector<int> deviceEL(EL, EL + edge_num);

	auto begin = thrust::make_zip_iterator(thrust::make_tuple(deviceSeg.begin(), deviceEL.begin()));
	auto end = thrust::make_zip_iterator(thrust::make_tuple(deviceSeg.end(), deviceEL.end()));

	thrust::sort(thrust::device, begin, end);

	generate_edgetocolumn_cuda(d_nodePointer, d_edgeList, thrust::raw_pointer_cast(&deviceEL[0]), d_edgeToColumn, d_blockPartition, block_num, BLK_H, BLK_W, num_nodes, d_hybrid_type);

	torch::Tensor row_nzr = torch::tensor({0}, opts), col_nzr = torch::tensor({0}, opts);

	return {blockPartition_tensor, edgeToColumn_tensor, edgeToRow_tensor, hybrid_type_tensor, row_nzr, col_nzr};
}

//////////////////////////////////////////////////////////////////////

void check_cuda(torch::Tensor t, std::string name) {
	if (t.device().is_cuda()) {
		std::cout << "Tensor " << name << " is on CUDA (device) memory.\n";
	} else {
		std::cout << "Tensor " << name << " is on CPU (host) memory.\n";
	}
}

void print_first(torch::Tensor tensor, const char* name, int count)
{
	auto tensor_cpu = tensor.to(torch::kCPU);
	std::cout << "First " << count << " elements of " << name << " (dtype = " << tensor.dtype() << " size = " << tensor.sizes() << "): [";

	torch::ScalarType dtype = tensor.scalar_type();
	switch (dtype) {
		case torch::kInt32: {
			auto data = tensor_cpu.data_ptr<int>();
			for (int i = 0; i < std::min<int64_t>(count, tensor_cpu.numel()); ++i)
				std::cout << data[i] << " ";
			break;
		}
		case torch::kInt64: {
			auto data = tensor_cpu.data_ptr<int64_t>();
			for (int i = 0; i < std::min<int64_t>(count, tensor_cpu.numel()); ++i)
				std::cout << data[i] << " ";
			break;
		}
		case torch::kFloat32: {
			auto data = tensor_cpu.data_ptr<float>();
			for (int i = 0; i < std::min<int64_t>(count, tensor_cpu.numel()); ++i)
				std::cout << data[i] << " ";
			break;
		}
		case torch::kFloat64: {
			auto data = tensor_cpu.data_ptr<double>();
			for (int i = 0; i < std::min<int64_t>(count, tensor_cpu.numel()); ++i)
				std::cout << data[i] << " ";
			break;
		}
		case torch::kUInt8: {
			auto data = tensor_cpu.data_ptr<uint8_t>();
			for (int i = 0; i < std::min<int64_t>(count, tensor_cpu.numel()); ++i)
				std::cout << static_cast<int>(data[i]) << " "; // print as int
			break;
		}
		default:
			std::cout << "Unsupported tensor dtype." << std::endl;
			return;
	}
	std::cout << "]\n";
}

template <typename T>
void copy_tensor_to_cpu(torch::Tensor tensor, T *output) {
	auto tensor_cpu = tensor.to(torch::kCPU);
	auto tensor_data = tensor_cpu.data_ptr<T>();
	for (int i = 0; i < tensor.size(0); i++) {
		output[i] = tensor_data[i];
	}
}

void preprocess_gpu_wrapper(int *row_ptr, int *col_idx,  int m, int n, int nnz,
	int * num_row_windows_out, int * blockSize_h_out, int * blockSize_w_out,
	int **nodePointer_ptr_out, int **edgeList_ptr_out, int **blockPartition_ptr_out, int **edgeToColumn_ptr_out, int **edgeToRow_ptr_out, int **hybrid_type_ptr_out, int **row_nzr_ptr_out, int **col_nzr_ptr_out,
	int *nodePointer_size_out, int *edgeList_size_out, int *blockPartition_size_out, int *edgeToColumn_size_out, int *edgeToRow_size_out, int *hybrid_type_size_out, int *row_nzr_size_out, int *col_nzr_size_out)
{
	// Allocate memory for edgeList_tensor and nodePointer_tensor on the GPU
	auto edgeList_tensor = torch::from_blob(col_idx, {nnz}, torch::kInt32).to(torch::kCUDA);
	auto nodePointer_tensor = torch::from_blob(row_ptr, {m + 1}, torch::kInt32).to(torch::kCUDA);

	int num_nodes = m;
	int num_edges = nnz;
	int blockSize_h = BLK_H;
	int blockSize_w = BLK_W;

	int num_row_windows = (num_nodes + blockSize_h - 1) / blockSize_h;

	auto [blockPartition, edgeToColumn, edgeToRow, hybrid_type, row_nzr, col_nzr] = preprocess(edgeList_tensor, nodePointer_tensor, num_nodes, num_edges, num_row_windows);

	*num_row_windows_out = num_row_windows;
	*blockSize_h_out = blockSize_h;
	*blockSize_w_out = blockSize_w;

	int * nodePointer_ptr = (int *)malloc(nodePointer_tensor.numel() * sizeof(int));
	copy_tensor_to_cpu<int>(nodePointer_tensor, nodePointer_ptr);

	int * edgeList_ptr = (int *)malloc(edgeList_tensor.numel() * sizeof(int));
	copy_tensor_to_cpu<int>(edgeList_tensor, edgeList_ptr);

	int * blockPartition_ptr = (int *)malloc(blockPartition.numel() * sizeof(int));
	copy_tensor_to_cpu<int>(blockPartition, blockPartition_ptr);

	int * edgeToColumn_ptr = (int *)malloc(edgeToColumn.numel() * sizeof(int));
	copy_tensor_to_cpu<int>(edgeToColumn, edgeToColumn_ptr);

	int * edgeToRow_ptr = (int *)malloc(edgeToRow.numel() * sizeof(int));
	copy_tensor_to_cpu<int>(edgeToRow, edgeToRow_ptr);

	int * hybrid_type_ptr = (int *)malloc(hybrid_type.numel() * sizeof(int));
	copy_tensor_to_cpu<int>(hybrid_type, hybrid_type_ptr);

	int * row_nzr_ptr = (int *)malloc(row_nzr.numel() * sizeof(int));
	copy_tensor_to_cpu<int>(row_nzr, row_nzr_ptr);

	int * col_nzr_ptr = (int *)malloc(col_nzr.numel() * sizeof(int));
	copy_tensor_to_cpu<int>(col_nzr, col_nzr_ptr);

	*nodePointer_ptr_out = nodePointer_ptr;
	*edgeList_ptr_out = edgeList_ptr;
	*blockPartition_ptr_out = blockPartition_ptr;
	*edgeToColumn_ptr_out = edgeToColumn_ptr;
	*edgeToRow_ptr_out = edgeToRow_ptr;
	*hybrid_type_ptr_out = hybrid_type_ptr;
	*row_nzr_ptr_out = row_nzr_ptr;
	*col_nzr_ptr_out = col_nzr_ptr;
	
	*nodePointer_size_out = nodePointer_tensor.numel();
	*edgeList_size_out = edgeList_tensor.numel();
	*blockPartition_size_out = blockPartition.numel();
	*edgeToColumn_size_out = edgeToColumn.numel();
	*edgeToRow_size_out = edgeToRow.numel();
	*hybrid_type_size_out = hybrid_type.numel();
	*row_nzr_size_out = row_nzr.numel();
	*col_nzr_size_out = col_nzr.numel();
}

//////////////////////////////////////////////////////////////////////

/************************************************************************/
/* FUNCTION DEFINITIONS */
// spmm_forward_fixed32 --> spmm_forward_plus_fixed32 --> spmm_forward_cuda_kernel_arbi_warps_hybrid_32
__global__ void spmm_forward_cuda_kernel_arbi_warps_hybrid_32(
		const int * __restrict__ nodePointer,		// node pointer.
		const int *__restrict__ edgeList,			// edge list.
		const int *__restrict__ blockPartition, 	// number of TC_blocks (16x8) in each row_window.
		const int *__restrict__ edgeToColumn, 		// eid -> col within each row_window.
		const int *__restrict__ edgeToRow, 		    // eid -> col within each row_window.
		const float *__restrict__ valuesA,
		const int numNodes,
		const int numEdges,
		const int embedding_dim,				    // embedding dimension.
		const float *__restrict__ input,		    // input feature matrix.
		float *output,							    // aggreAGNNed output feature matrix.
		const int *__restrict__ hybrid_type,
		const int *__restrict__ row_nzr,
		const int *__restrict__ col_nzr
		) 
{
	unsigned bid = blockIdx.x;								// block_index == row_window_index
	unsigned wid = threadIdx.y;								// warp_index handling multi-dimension > 16.
	const unsigned laneid = threadIdx.x;							// lanid of each warp.
	const unsigned tid = threadIdx.y * blockDim.x + laneid;			// threadid of each block.
										// const unsigned warpSize = blockDim.x;							// number of threads per warp.
	const unsigned threadPerBlock = blockDim.x * blockDim.y;		// number of threads per block.

	const unsigned dimTileNum = embedding_dim / BLK_H;              // number of tiles along the dimension
	unsigned nIdx_start = bid * BLK_H;					    // starting nodeIdx of current row_window.
	unsigned nIdx_end = min((bid + 1) * BLK_H, numNodes);		// ending nodeIdx of current row_window.

	unsigned eIdx_start = nodePointer[nIdx_start];			// starting edgeIdx of current row_window.
	unsigned eIdx_end = nodePointer[nIdx_end];				// ending edgeIdx of the current row_window.
	unsigned num_TC_blocks = blockPartition[bid]; 			// number of TC_blocks of the current row_window.
	const unsigned dense_bound = numNodes * embedding_dim;

	__shared__ float sparse_A[BLK_H * BLK_W * MAX_BLK];					// row-major sparse matrix shared memory store.
	__shared__ int sparse_AToX_index[BLK_W * MAX_BLK];					// TC_block col to dense_tile row.

	extern __shared__ float dense_X[];

	__shared__ int tmp_A[S_SIZE];
	__shared__ float tmp_A_values[S_SIZE];

	if(hybrid_type[bid] == 0){

		// int end_nzr = row_nzr[bid + 1];
		int end_nzr = (bid + 1) * BLK_H > numNodes ? numNodes : (bid + 1) * BLK_H;

		unsigned begin_edge = nodePointer[bid * 16], end_edge = nodePointer[min((bid + 1) * 16, numNodes)];
		for(int i = begin_edge + tid; i < end_edge; i += threadPerBlock){
			tmp_A[i - begin_edge] = edgeList[i];
		}
		__syncthreads();

		// for (int z = row_nzr[bid] + wid; z < end_nzr; z += WPB) {
		for (int z = bid * BLK_H + wid; z < end_nzr; z += WPB) {
			// int row = col_nzr[z];
			int row = z;
			int target_id = row * embedding_dim + laneid;
			int begin_col_id = nodePointer[row], end_col_id = nodePointer[row + 1];
			float acc = 0.0;
			for (int j = begin_col_id; j < end_col_id; j++) {
				// acc += input[laneid + edgeList[j] * embedding_dim];
				// acc += input[laneid + tmp_A[j - begin_edge] * embedding_dim];
				// this is what I changed, in order to perform a multiplication too, apart from the addition...
				acc += input[laneid + tmp_A[j - begin_edge] * embedding_dim] * valuesA[j];
			}
			output[target_id] = acc;
		}
	}
	else{
		wmma::fragment<wmma::matrix_a, BLK_H, BLK_H, BLK_W, wmma::precision::tf32, wmma::row_major> a_frag;
		wmma::fragment<wmma::matrix_b, BLK_H, BLK_H, BLK_W, wmma::precision::tf32, wmma::col_major> b_frag;
		wmma::fragment<wmma::accumulator, BLK_H, BLK_H, BLK_W, float> acc_frag;
		wmma::fill_fragment(acc_frag, 0.0f);

		// nIdx_start = bid * BLK_H;					    // starting nodeIdx of current row_window.
		// nIdx_end = min((bid + 1) * BLK_H, numNodes);		// ending nodeIdx of current row_window.

		// eIdx_start = nodePointer[nIdx_start];			// starting edgeIdx of current row_window.
		// eIdx_end = nodePointer[nIdx_end];				// ending edgeIdx of the current row_window.
		// num_TC_blocks = blockPartition[bid];

		// Init A_colToX_row with dummy values.
		if (tid < BLK_W * MAX_BLK) {
			sparse_AToX_index[tid] = numNodes + 1;
		}

		__syncthreads();

		// Init sparse_A with zero values.
		#pragma unroll
		for (unsigned idx = tid; idx < BLK_W * BLK_H * MAX_BLK; idx += threadPerBlock) {
			sparse_A[idx] = 0;
		}

		// #pragma unroll
		// // Init dense_X with zero values.
		// for (unsigned idx = tid; idx < dimTileNum * BLK_W * BLK_H; idx += threadPerBlock) {
		//     dense_X[idx] = 0;
		// }

		#pragma unroll
		for (unsigned eIdx = eIdx_start + tid; eIdx < eIdx_end; eIdx += threadPerBlock) {
			unsigned col = edgeToColumn[eIdx];
			unsigned row_local = edgeToRow[eIdx] % BLK_H;
			unsigned blk_id = col / 8;
			unsigned col_local = col % 8;
			// sparse_A[row_local * BLK_W + col_local + blk_id * BLK_H * BLK_W] = 1;        // set the edge of the sparse_A.
			sparse_A[row_local * BLK_W + col_local + blk_id * BLK_H * BLK_W] = valuesA[eIdx];        // set the edge of the sparse_A.
			sparse_AToX_index[col] = edgeList[eIdx];        // record the mapping from sparse_A colId to rowId of dense_X.
		}

		__syncthreads();

		for (unsigned i = 0; i < num_TC_blocks; i++) {
			#pragma unroll
			for (unsigned idx = wid; idx < BLK_W; idx += WPB) {
				unsigned dense_rowIdx = sparse_AToX_index[idx % BLK_W + i * BLK_W];                        // TC_block_col to dense_tile_row.
				unsigned source_idx = dense_rowIdx * embedding_dim + laneid;
				unsigned target_idx = laneid * BLK_W + idx;
				// boundary test.
				dense_X[target_idx] = source_idx < dense_bound ? __ldca(&input[source_idx]) : 0;
			}

			__syncthreads();

			if (wid < dimTileNum) {
				wmma::load_matrix_sync(a_frag, sparse_A + i * BLK_W * BLK_H, BLK_W);
				wmma::load_matrix_sync(b_frag, dense_X + wid * BLK_W * BLK_H, BLK_W);
				#pragma unroll
				for (unsigned t = 0; t < a_frag.num_elements; t++) {
					a_frag.x[t] = wmma::__float_to_tf32(a_frag.x[t]);
				}

				#pragma unroll
				for (unsigned t = 0; t < b_frag.num_elements; t++) {
					b_frag.x[t] = wmma::__float_to_tf32(b_frag.x[t]);
				}
				// Perform the matrix multiplication.
				wmma::mma_sync(acc_frag, a_frag, b_frag, acc_frag);
			}

		}
		if (wid < dimTileNum)
			// Store the matrix to output matrix.
			// * Note * embeeding dimension should be padded divisible by BLK_H for output correctness.
			wmma::store_matrix_sync(output + bid * BLK_H * embedding_dim + wid * BLK_H, acc_frag, embedding_dim,
					wmma::mem_row_major);
	}
	
}

/************************************************************************/
