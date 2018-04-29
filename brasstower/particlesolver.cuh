#pragma once

#include <exception>
#include <cuda_runtime.h>
#include <device_launch_parameters.h>
#include <cuda_gl_interop.h>
#include <conio.h>

#ifndef __INTELLISENSE__
#include <cub/cub.cuh>
#endif

#include "cuda/helper.cuh"
#include "cuda/cudamatrix.cuh"
#include "cuda/cudaglm.cuh"
#include "scene.h"

#define NUM_MAX_PARTICLE_PER_CELL 15
#define FRICTION_STATIC 0.0f
#define FRICTION_DYNAMICS 0.0f
#define MASS_SCALING_CONSTANT 2 // refers to k in equation (21)
#define PARTICLE_SLEEPING_EPSILON 0.00

void GetNumBlocksNumThreads(int * numBlocks, int * numThreads, int k)
{
	*numThreads = 512;
	*numBlocks = static_cast<int>(ceil((float)k / (float)(*numThreads)));
}

template <typename T>
void print(T * dev, int size)
{
	T * tmp = (T *)malloc(sizeof(T) * size);
	cudaMemcpy(tmp, dev, sizeof(T) * size, cudaMemcpyDeviceToHost);
	for (int i = 0; i < size; i++)
	{
		std::cout << tmp[i];
		if (i != size - 1)
			std::cout << ",";
	}
	std::cout << std::endl;
	free(tmp);
}

template <>
void print<float3>(float3 * dev, int size)
{
	float3 * tmp = (float3 *)malloc(sizeof(float3) * size);
	cudaMemcpy(tmp, dev, sizeof(float3) * size, cudaMemcpyDeviceToHost);
	for (int i = 0; i < size; i++)
	{
		std::cout << "(" << tmp[i].x << " " << tmp[i].y << " " << tmp[i].z << ")";
		if (i != size - 1)
			std::cout << ",";
	}
	std::cout << std::endl;
	free(tmp);
}

template <typename T>
void printPair(T * dev, int size)
{
	T * tmp = (T *)malloc(sizeof(T) * size);
	cudaMemcpy(tmp, dev, sizeof(T) * size, cudaMemcpyDeviceToHost);
	for (int i = 0; i < size; i++)
	{
		if (tmp[i] != -1)
		{
			std::cout << i << ":" << tmp[i];
			if (i != size - 1)
				std::cout << ",";
		}
	}
	std::cout << std::endl;
	free(tmp);
}

// PARTICLE SYSTEM //

__global__ void increment(int * __restrict__ x)
{
	atomicAdd(x, 1);
}

__global__ void setDevArr_devIntPtr(int * __restrict__ devArr,
								    const int * __restrict__ value,
								    const int numValues)
{
	int i = threadIdx.x + __mul24(blockIdx.x, blockDim.x);
	if (i >= numValues) { return; }
	devArr[i] = *value;
}

__global__ void setDevArr_int(int * __restrict__ devArr,
						  const int value,
						  const int numValues)
{
	int i = threadIdx.x + __mul24(blockIdx.x, blockDim.x);
	if (i >= numValues) { return; }
	devArr[i] = value;
}

__global__ void setDevArr_float(float * __restrict__ devArr,
								const float value,
								const int numValues)
{
	int i = threadIdx.x + __mul24(blockIdx.x, blockDim.x);
	if (i >= numValues) { return; }
	devArr[i] = value;
}

__global__ void setDevArr_int2(int2 * __restrict__ devArr,
							   const int2 value,
							   const int numValues)
{
	int i = threadIdx.x + __mul24(blockIdx.x, blockDim.x);
	if (i >= numValues) { return; }
	devArr[i] = value;
}

__global__ void setDevArr_float3(float3 * __restrict__ devArr,
								 const float3 val,
								 const int numValues)
{
	int i = threadIdx.x + __mul24(blockIdx.x, blockDim.x);
	if (i >= numValues) { return; }
	devArr[i] = val;
}

__global__ void setDevArr_float4(float4 * __restrict__ devArr,
								 const float4 val,
								 const int numValues)
{
	int i = threadIdx.x + __mul24(blockIdx.x, blockDim.x);
	if (i >= numValues) { return; }
	devArr[i] = val;
}

__global__ void setDevArr_counterIncrement(int * __restrict__ devArr,
										  int * counter,
										  const int incrementValue,
										  const int numValues)
{
	int i = threadIdx.x + __mul24(blockIdx.x, blockDim.x);
	if (i >= numValues) { return; }
	devArr[i] = atomicAdd(counter, incrementValue);
}

__global__ void initPositionBox(float3 * __restrict__ positions,
								int * __restrict__ phases,
								int * phaseCounter,
								const int3 dimension,
								const float3 startPosition,
								const float3 step,
								const int numParticles)
{
	int i = threadIdx.x + __mul24(blockIdx.x, blockDim.x);
	if (i >= numParticles) { return; }
	int x = i % dimension.x;
	int y = (i / dimension.x) % dimension.y;
	int z = i / (dimension.x * dimension.y);
	positions[i] = make_float3(x, y, z) * step + startPosition;
	phases[i] = atomicAdd(phaseCounter, 1);
}

// GRID //
// from White Paper "Particles" by SIMON GREEN 

__device__ int3 calcGridPos(float3 position,
							float3 origin,
							float3 cellSize)
{
	return make_int3((position - origin) / cellSize);
}

__device__ int positiveMod(int dividend, int divisor)
{
	return (dividend % divisor + divisor) % divisor;
}

__device__ int calcGridAddress(int3 gridPos, int3 gridSize)
{
	gridPos = make_int3(positiveMod(gridPos.x, gridSize.x), positiveMod(gridPos.y, gridSize.y), positiveMod(gridPos.z, gridSize.z));
	return (gridPos.z * gridSize.y * gridSize.x) + (gridPos.y * gridSize.x) + gridPos.x;
}

__global__ void updateGridId(int * __restrict__ gridIds,
							 int * __restrict__ particleIds,
							 const float3 * __restrict__ positions,
							 const float3 cellOrigin,
							 const float3 cellSize,
							 const int3 gridSize,
							 const int numParticles)
{
	int i = threadIdx.x + __mul24(blockIdx.x, blockDim.x);
	if (i >= numParticles) { return; }

	int3 gridPos = calcGridPos(positions[i], cellOrigin, cellSize);
	int gridId = calcGridAddress(gridPos, gridSize);

	gridIds[i] = gridId;
	particleIds[i] = i;
}

__global__ void findStartId(int * cellStart,
							const int * sortedGridIds,
							const int numParticles)
{
	int i = threadIdx.x + __mul24(blockIdx.x, blockDim.x);
	if (i >= numParticles) { return; }

	int cell = sortedGridIds[i];

	if (i > 0)
	{
		if (cell != sortedGridIds[i - 1]) 
			cellStart[cell] = i;
	}
	else
	{
		cellStart[cell] = i;
	}
}

// SOLVER //

__global__ void applyForces(float3 * __restrict__ velocities,
							const float * __restrict__ invMass,
							const int numParticles,
							const float deltaTime)
{
	int i = threadIdx.x + __mul24(blockIdx.x, blockDim.x);
	if (i >= numParticles) { return; }
	velocities[i] += make_float3(0.0f, -9.8f, 0.0f) * deltaTime;
}

__global__ void predictPositions(float3 * __restrict__ newPositions,
								 const float3 * __restrict__ positions,
								 const float3 * __restrict__ velocities,
								 const int numParticles,
								 const float deltaTime)
{
	int i = threadIdx.x + __mul24(blockIdx.x, blockDim.x);
	if (i >= numParticles) { return; }
	newPositions[i] = positions[i] + velocities[i] * deltaTime;
}

__global__ void updateVelocity(float3 * __restrict__ velocities,
							   const float3 * __restrict__ newPositions,
							   const float3 * __restrict__ positions,
							   const int numParticles,
							   const float invDeltaTime)
{
	int i = threadIdx.x + __mul24(blockIdx.x, blockDim.x);
	if (i >= numParticles) { return; }
	velocities[i] = (newPositions[i] - positions[i]) * invDeltaTime;
}

__global__ void planeStabilize(float3 * __restrict__ positions,
							   float3 * __restrict__ newPositions,
							   const int numParticles,
							   const float3 planeOrigin,
							   const float3 planeNormal,
							   const float radius)
{
	int i = threadIdx.x + __mul24(blockIdx.x, blockDim.x);
	if (i >= numParticles) { return; }
	float3 origin2position = planeOrigin - positions[i];
	float distance = dot(origin2position, planeNormal) + radius;
	if (distance <= 0) { return; }

	positions[i] += distance * planeNormal;
	newPositions[i] += distance * planeNormal;
}

// PROJECT CONSTRAINTS //

__global__ void particlePlaneCollisionConstraint(float3 * __restrict__ newPositions,
												 float3 * __restrict__ positions,
												 const int numParticles,
												 const float3 planeOrigin,
												 const float3 planeNormal,
												 const float radius)
{
	int i = threadIdx.x + __mul24(blockIdx.x, blockDim.x);
	if (i >= numParticles) { return; }
	float3 origin2position = planeOrigin - newPositions[i];
	float distance = dot(origin2position, planeNormal) + radius;
	if (distance <= 0) { return; }

	float3 position = positions[i];

	float3 diff = newPositions[i] - position;
	float diffNormal = dot(diff, planeNormal);
	float3 diffTangent = diff - diffNormal * planeNormal;
	float diffTangentLength = length(diffTangent);
	float diffLength = length(diff);
	
	float3 resolvedPosition = distance * planeNormal + newPositions[i];
	float3 deltaX = resolvedPosition - position;
	float3 tangentialDeltaX = deltaX - dot(deltaX, planeNormal) * planeNormal;

	//positions[i] += (2.0f * diffNormal + distance) * planeNormal * ENERGY_LOST_RATIO;

	// Adaptation of Unified Particle Physics for Real-Time Applications, eq.24 
	if (diffTangentLength < FRICTION_STATIC * diffNormal)
	{
		newPositions[i] = resolvedPosition - tangentialDeltaX;
	}
	else
	{
		newPositions[i] = resolvedPosition - tangentialDeltaX * min(FRICTION_DYNAMICS * -diffNormal / diffTangentLength, 1.0f);
	}
}

__global__ void particleParticleCollisionConstraint(float3 * __restrict__ newPositionsNext,
													const float3 * __restrict__ newPositionsPrev,
													const float3 * __restrict__ positions,
													const float * __restrict__ invMasses,
													const int* __restrict__ phases,
													const int* __restrict__ sortedCellId,
													const int* __restrict__ sortedParticleId,
													const int* __restrict__ cellStart, 
													const float3 cellOrigin,
													const float3 cellSize,
													const int3 gridSize,
													const int numParticles,
													const float radius)
{
	int i = threadIdx.x + __mul24(blockIdx.x, blockDim.x);
	if (i >= numParticles) { return; }

	float3 xi = positions[i];
	float3 xiPrev = newPositionsPrev[i];
	float3 sumDeltaXi = make_float3(0.f);
	float3 sumFriction = make_float3(0.f);
	float invMass = invMasses[i];

	int3 centerGridPos = calcGridPos(newPositionsPrev[i], cellOrigin, cellSize);
	int3 start = centerGridPos - 1;
	int3 end = centerGridPos + 1;

	int constraintCount = 0;
	for (int z = start.z; z <= end.z; z++)
		for (int y = start.y; y <= end.y; y++)
			for (int x = start.x; x <= end.x; x++)
			{
				int3 gridPos = make_int3(x, y, z);
				int gridAddress = calcGridAddress(gridPos, gridSize);
				int bucketStart = cellStart[gridAddress];
				if (bucketStart == -1) { continue; }

				for (int k = 0; k + bucketStart < numParticles; k++)
				{
					int gridAddress2 = sortedCellId[bucketStart + k];
					int particleId2 = sortedParticleId[bucketStart + k];
					if (gridAddress2 != gridAddress) { break; }

					if (i != particleId2 && phases[i] != phases[particleId2])
					{
						float3 xjPrev = newPositionsPrev[particleId2];
						float3 diff = xiPrev - xjPrev;
						float dist2 = length2(diff);
						if (dist2 < radius * radius * 4.0f)
						{
							float dist = sqrtf(dist2);
							float invMass2 = invMasses[particleId2];
							float weight1 = invMass / (invMass + invMass2);

							float3 projectDir = diff * (2.0f * radius / dist - 1.0f); 
							float3 deltaXi = weight1 * projectDir;
							float3 xiStar = deltaXi + xiPrev;
							sumDeltaXi += deltaXi;

							float deltaXiLength2 = length2(deltaXi);
							
							if (deltaXiLength2 > radius * radius * 0.001f * 0.001f)
							{
								constraintCount += 1;
								float weight2 = invMass2 / (invMass + invMass2);
								float3 xj = positions[particleId2];
								float3 deltaXj = -weight2 * projectDir;
								float3 xjStar = deltaXj + xjPrev;
								float3 term1 = (xiStar - xi) - (xjStar - xj);
								float3 n = diff / dist;
								float3 tangentialDeltaX = term1 - dot(term1, n) * n;

								float tangentialDeltaXLength2 = length2(tangentialDeltaX);

								if (tangentialDeltaXLength2 <= (FRICTION_STATIC * FRICTION_STATIC) * deltaXiLength2)
								{
									sumFriction -= weight1 * tangentialDeltaX;
								}
								else
								{
									sumFriction -= weight1 * tangentialDeltaX * min(FRICTION_DYNAMICS * sqrtf(deltaXiLength2 / tangentialDeltaXLength2), 1.0f);
								}
							}
						}
					}
				}
			}

	newPositionsNext[i] = (constraintCount == 0) ?
		xiPrev + sumDeltaXi :
		xiPrev + sumDeltaXi + sumFriction / constraintCount; // averaging constraints is very important here. otherwise the solver will explode.
}

__global__ void computeInvScaledMasses(float* __restrict__ invScaledMasses,
									   const float* __restrict__ masses,
									   const float3* __restrict__ positions,
									   const float k,
									   const int numParticles)
{
	int i = threadIdx.x + __mul24(blockIdx.x, blockDim.x);
	if (i >= numParticles) { return; }

	const float e = 2.7182818284f;
	const float height = positions[i].y;
	const float scale = pow(e, -k * height);
	invScaledMasses[i] = 1.0f / (scale * masses[i]);
}

// Meshless Deformations Based on Shape Matching
// by Muller et al.

// one block per one shape
#define NUM_MAX_PARTICLE_PER_RIGID_BODY 64
__global__ void shapeMatchingAlphaOne(quaternion * __restrict__ rotations,
									  float3 * __restrict__ CMs,
									  float3 * __restrict__ positions,
									  const float3 * __restrict__ initialPositions,
									  const int2 * __restrict__ rigidBodyParticleIdRange)
{
	// typename stuffs
	typedef cub::BlockReduce<float3, NUM_MAX_PARTICLE_PER_RIGID_BODY> BlockReduceFloat3;
	__shared__ typename BlockReduceFloat3::TempStorage TempStorageFloat3;

	// init rigidBodyId, particleRange and numParticles
	int rigidBodyId = blockIdx.x;
	int2 particleRange = rigidBodyParticleIdRange[rigidBodyId];

	int numParticles = particleRange.y - particleRange.x;
	int particleId = particleRange.x + threadIdx.x;

	float3 position = positions[particleId];

	__shared__ float3 CM;
	__shared__ matrix3 extractedR;

	if (threadIdx.x < numParticles)
	{
		// find center of mass using block reduce
		float3 sumCM = BlockReduceFloat3(TempStorageFloat3).Sum(position);

		if (threadIdx.x == 0)
		{
			CM = sumCM / (float)numParticles;
			CMs[rigidBodyId] = CM;
		}
	}
	__syncthreads();

	float3 qi;
	if (threadIdx.x < numParticles)
	{
		// compute matrix Apq
		float3 initialPosition = initialPositions[particleId];
		float3 pi = position - CM;
		qi = initialPosition;// do not needed to subtract from initialCM since initialCM = float3(0);

		// Matrix Ai refers to p * q
		float3 AiCol0 = pi * qi.x;
		float3 AiCol1 = pi * qi.y;
		float3 AiCol2 = pi * qi.z;

		// Matrix A refers to Apq
		float3 ACol0 = BlockReduceFloat3(TempStorageFloat3).Sum(AiCol0);
		float3 ACol1 = BlockReduceFloat3(TempStorageFloat3).Sum(AiCol1);
		float3 ACol2 = BlockReduceFloat3(TempStorageFloat3).Sum(AiCol2);

		if (threadIdx.x == 0)
		{
			// extract rotation matrix using method 
			// using A Robust Method to Extract the Rotational Part of Deformations
			// by Muller et al.

			quaternion q = rotations[rigidBodyId];
			matrix3 R = extract_rotation_matrix3(q);
			for (int i = 0; i < 20; i++)
			{
				matrix3 R = extract_rotation_matrix3(q);
				float3 omegaNumerator = (cross(R.col[0], ACol0) +
										 cross(R.col[1], ACol1) +
										 cross(R.col[2], ACol2));
				float omegaDenominator = 1.0f / fabs(dot(R.col[0], ACol0) +
													 dot(R.col[1], ACol1) +
													 dot(R.col[2], ACol2)) + 1e-9f;
				float3 omega = omegaNumerator * omegaDenominator;
				float w2 = length2(omega);
				if (w2 <= 1e-9f) { break; }
				float w = sqrtf(w2);

				q = mul(angleAxis(omega / w, w), q);
				q = normalize(q);
			}
			extractedR = extract_rotation_matrix3(q);
			rotations[rigidBodyId] = q;
		}
	}
	__syncthreads();

	if (threadIdx.x < numParticles)
	{
		float3 newPosition = extractedR * qi + CM;
		positions[particleId] = newPosition;
	}
}

__device__ __constant__ float KernelConst1;
__device__ __constant__ float KernelConst2;
__device__ __constant__ float KernelConst3;
__device__ __constant__ float KernelConst4;
__device__ __constant__ int3 FluidGridSearchSize;
__device__ __constant__ float KernelRadius;
__device__ __constant__ float KernelSquaredRadius;
__device__ __constant__ float KernelHalfRadius;

void SetKernelRadius(float h)
{
	float const1 = 315.f / 64.f / 3.141592f / powf(h, 9.0f);
	checkCudaErrors(cudaMemcpyToSymbol(KernelConst1, &const1, sizeof(float)));
	float const2 = -45.f / 3.141592f / powf(h, 6.f);
	checkCudaErrors(cudaMemcpyToSymbol(KernelConst2, &const2, sizeof(float)));
	float const3 = 32.0f / 3.141592f / powf(h, 9.f);
	checkCudaErrors(cudaMemcpyToSymbol(KernelConst3, &const3, sizeof(float)));
	float const4 = powf(h, 6.0f) / 64.0f;
	checkCudaErrors(cudaMemcpyToSymbol(KernelConst4, &const4, sizeof(float)));
	float const5 = h * h;
	checkCudaErrors(cudaMemcpyToSymbol(KernelSquaredRadius, &const5, sizeof(float)));
	float const6 = h * 0.5f;
	checkCudaErrors(cudaMemcpyToSymbol(KernelHalfRadius, &const6, sizeof(float)));
	float const7 = h;
	checkCudaErrors(cudaMemcpyToSymbol(KernelRadius, &const7, sizeof(float)));
}

__device__ float poly6Kernel(float r2)
{
	/// TODO:: precompute these
	if (r2 <= KernelSquaredRadius)
	{
		float temp = KernelSquaredRadius - r2;
		return KernelConst1 * temp * temp * temp;
	}
	return 0.f;
}

__device__ float3 gradientSpikyKernel(const float3 v, const float r2)
{
	if (r2 <= KernelSquaredRadius && r2 > 0.f)
	{
		float r = sqrtf(r2);
		float temp = KernelRadius - r;
		return KernelConst2 * temp * temp * v / r;
	}
	return make_float3(0.f);
}

__device__ float akinciSplineC(float r) // akinci used 2*r instead of r
{
	if (r < KernelRadius && r > 0)
	{
		float temp = (KernelRadius - r) * r;
		float temp3 = temp * temp * temp;
		if (r >= KernelHalfRadius)
			return KernelConst3 * temp3;
		else
			return 2.0f * KernelConst3 * temp3 - KernelConst4;
	}
	return 0.f;
}

__global__ void fluidLambda(float * __restrict__ lambdas,
							float * __restrict__ densities,
							const float3 * __restrict__ newPositionsPrev,
							const float * __restrict__ masses,
							const int * __restrict__ phases,
							const float restDensity,
							const float epsilon,
							const int* __restrict__ sortedCellId,
							const int* __restrict__ sortedParticleId,
							const int* __restrict__ cellStart,
							const float3 cellOrigin,
							const float3 cellSize,
							const int3 gridSize,
							const int3 gridSearchOffset,
							const int numParticles,
							const bool useAkinciCohesionTension)
{
	int i = threadIdx.x + __mul24(blockIdx.x, blockDim.x);
	if (i >= numParticles || phases[i] > 0) { return; }

	float3 pi = newPositionsPrev[i];

	// compute density and gradient of constraint
	float density = 0.f;
	float3 gradientI = make_float3(0.f);
	float sumGradient2 = 0.f;

	int3 centerGridPos = calcGridPos(newPositionsPrev[i], cellOrigin, cellSize);
	int3 start = centerGridPos - gridSearchOffset;
	int3 end = centerGridPos + gridSearchOffset;

	int constraintCount = 0;

	for (int z = start.z; z <= end.z; z++)
		for (int y = start.y; y <= end.y; y++)
			for (int x = start.x; x <= end.x; x++)
			{
				int3 gridPos = make_int3(x, y, z);
				int gridAddress = calcGridAddress(gridPos, gridSize);
				int bucketStart = cellStart[gridAddress];
				if (bucketStart == -1) { continue; }

				for (int k = 0; k < NUM_MAX_PARTICLE_PER_CELL && k + bucketStart < numParticles; k++)
				{
					int gridAddress2 = sortedCellId[bucketStart + k];
					if (gridAddress2 != gridAddress) { break; }

					int j = sortedParticleId[bucketStart + k];
					if (phases[j] < 0) /// TODO:: also takecare of solid
					{
						float3 pj = newPositionsPrev[j];
						float3 diff = pi - pj;
						float dist2 = length2(pi - pj);
						density += poly6Kernel(dist2);
						float3 gradient = - /*mass * */ gradientSpikyKernel(diff, dist2) / restDensity;
						sumGradient2 += dot(gradient, gradient);
						gradientI -= gradient;
					}
				}
			}

	sumGradient2 += dot(gradientI, gradientI);

	// compute constraint
	float constraint = density / restDensity - 1.0f;
	if (useAkinciCohesionTension) { constraint = max(constraint, 0.0f); }
	float lambda = -constraint / (sumGradient2 + epsilon);
	lambdas[i] = lambda;
	densities[i] = density;
}

__global__ void fluidPosition(float3 * __restrict__ newPositionsNext,
							  const float3 * __restrict__ newPositionsPrev,
							  const float * __restrict__ lambdas,
							  const float restDensity,
							  const int * __restrict__ phases,
							  const float K,
							  const int N,
							  const int* __restrict__ sortedCellId,
							  const int* __restrict__ sortedParticleId,
							  const int* __restrict__ cellStart,
							  const float3 cellOrigin,
							  const float3 cellSize,
							  const int3 gridSize,
							  const int3 gridSearchOffset,
							  const int numParticles,
							  const bool useAkinciCohesionTension)
{
	int i = threadIdx.x + __mul24(blockIdx.x, blockDim.x);
	if (i >= numParticles || phases[i] > 0) { return; }

	float3 pi = newPositionsPrev[i];

	float3 sum = make_float3(0.f);
	int3 centerGridPos = calcGridPos(newPositionsPrev[i], cellOrigin, cellSize);
	int3 start = centerGridPos - gridSearchOffset;
	int3 end = centerGridPos + gridSearchOffset;

	int constraintCount = 0;

	for (int z = start.z; z <= end.z; z++)
		for (int y = start.y; y <= end.y; y++)
			for (int x = start.x; x <= end.x; x++)
			{
				int3 gridPos = make_int3(x, y, z);
				int gridAddress = calcGridAddress(gridPos, gridSize);
				int bucketStart = cellStart[gridAddress];
				if (bucketStart == -1) { continue; }

				for (int k = 0; k < NUM_MAX_PARTICLE_PER_CELL && k + bucketStart < numParticles; k++)
				{
					int gridAddress2 = sortedCellId[bucketStart + k];
					if (gridAddress2 != gridAddress) { break; }

					int j = sortedParticleId[bucketStart + k];
					if (i != j && phases[j] < 0)
					{
						float3 pj = newPositionsPrev[j];
						float sumLambda = lambdas[i] + lambdas[j];
						float3 diff = pi - pj;
						float dist2 = length2(diff);
						if (!useAkinciCohesionTension) sumLambda += -K * powf(poly6Kernel(dist2) / poly6Kernel(powf(0.03f * KernelRadius, 2.f)), N);
						sum += sumLambda * gradientSpikyKernel(pi - pj, dist2);
					}
				}
			}

	float3 deltaPosition = sum / restDensity;
	newPositionsNext[i] = pi + deltaPosition;
}

/// TODO:: optimize this by plug it in last loop of fluidPosition
__global__ void fluidOmega(float3 * __restrict__ omegas,
						   const float3 * __restrict__ velocities,
						   const float3 * __restrict__ positions,
						   const int * __restrict__ phases,
						   const int* __restrict__ sortedCellId,
						   const int* __restrict__ sortedParticleId,
						   const int* __restrict__ cellStart,
						   const float3 cellOrigin,
						   const float3 cellSize,
						   const int3 gridSize,
						   const int3 gridSearchOffset,
						   const int numParticles)
{
	int i = threadIdx.x + __mul24(blockIdx.x, blockDim.x);
	if (i >= numParticles || phases[i] > 0) { return; }

	float3 pi = positions[i];
	float3 vi = velocities[i];

	float3 omegai = make_float3(0.f);
	int3 centerGridPos = calcGridPos(positions[i], cellOrigin, cellSize);
	int3 start = centerGridPos - gridSearchOffset;
	int3 end = centerGridPos + gridSearchOffset;

	int constraintCount = 0;

	for (int z = start.z; z <= end.z; z++)
		for (int y = start.y; y <= end.y; y++)
			for (int x = start.x; x <= end.x; x++)
			{
				int3 gridPos = make_int3(x, y, z);
				int gridAddress = calcGridAddress(gridPos, gridSize);
				int bucketStart = cellStart[gridAddress];
				if (bucketStart == -1) { continue; }

				for (int k = 0; k < NUM_MAX_PARTICLE_PER_CELL && k + bucketStart < numParticles; k++)
				{
					int gridAddress2 = sortedCellId[bucketStart + k];
					if (gridAddress2 != gridAddress) { break; }

					int j = sortedParticleId[bucketStart + k];
					if (i != j && phases[j] < 0)
					{
						float3 pj = positions[j];
						float3 vj = velocities[j];
						float3 diff = pi - pj;
						omegai += cross(vj - vi, gradientSpikyKernel(diff, length2(diff)));
					}
				}
			}
	
	omegas[i] = omegai;
}

__global__ void fluidVorticity(float3 * __restrict__ velocities,
							   const float3 * __restrict__ omegas,
							   const float3 * __restrict__ positions,
							   const float scalingFactor,
							   const int * __restrict__ phases,
							   const int* __restrict__ sortedCellId,
							   const int* __restrict__ sortedParticleId,
							   const int* __restrict__ cellStart,
							   const float3 cellOrigin,
							   const float3 cellSize,
							   const int3 gridSize,
							   const int3 gridSearchOffset,
							   const int numParticles,
							   const float deltaTime)
{
	int i = threadIdx.x + __mul24(blockIdx.x, blockDim.x);
	if (i >= numParticles || phases[i] > 0) { return; }

	float3 omegai = omegas[i];
	float3 pi = positions[i];
	int3 centerGridPos = calcGridPos(positions[i], cellOrigin, cellSize);
	int3 start = centerGridPos - gridSearchOffset;
	int3 end = centerGridPos + gridSearchOffset;
	float3 eta = make_float3(0.f);

	for (int z = start.z; z <= end.z; z++)
		for (int y = start.y; y <= end.y; y++)
			for (int x = start.x; x <= end.x; x++)
			{
				int3 gridPos = make_int3(x, y, z);
				int gridAddress = calcGridAddress(gridPos, gridSize);
				int bucketStart = cellStart[gridAddress];
				if (bucketStart == -1) { continue; }

				for (int k = 0; k < NUM_MAX_PARTICLE_PER_CELL && k + bucketStart < numParticles; k++)
				{
					int gridAddress2 = sortedCellId[bucketStart + k];
					if (gridAddress2 != gridAddress) { break; }

					int j = sortedParticleId[bucketStart + k];
					if (i != j && phases[j] < 0)
					{
						float3 pj = positions[j];
						float3 diff = pi - pj;
						eta += length(omegas[j]) * gradientSpikyKernel(diff, length2(diff));
					}
				}
			}

	if (length2(eta) > 1e-3f)
	{
		float3 normal = normalize(eta);

		/// TODO:: also have to be devided by mass
		velocities[i] += scalingFactor * cross(normal, omegai) * deltaTime;
	}
}

__global__ void fluidXSph(float3 * __restrict__ newVelocities,
						  const float3 * __restrict__ velocities,
						  const float3 * __restrict__ positions,
						  const float c, // position-based fluid eq. 17
						  const int * __restrict__ phases,
						  const int* __restrict__ sortedCellId,
						  const int* __restrict__ sortedParticleId,
						  const int* __restrict__ cellStart,
						  const float3 cellOrigin,
						  const float3 cellSize,
						  const int3 gridSize,
						  const int3 gridSearchOffset,
						  const int numParticles)
{
	int i = threadIdx.x + __mul24(blockIdx.x, blockDim.x);
	if (i >= numParticles || phases[i] > 0) { return; }

	float3 pi = positions[i];
	int3 centerGridPos = calcGridPos(pi, cellOrigin, cellSize);
	int3 start = centerGridPos - gridSearchOffset;
	int3 end = centerGridPos + gridSearchOffset;

	float3 vnew = make_float3(0.f);
	float3 vi = velocities[i];

	for (int z = start.z; z <= end.z; z++)
		for (int y = start.y; y <= end.y; y++)
			for (int x = start.x; x <= end.x; x++)
			{
				int3 gridPos = make_int3(x, y, z);
				int gridAddress = calcGridAddress(gridPos, gridSize);
				int bucketStart = cellStart[gridAddress];
				if (bucketStart == -1) { continue; }

				for (int k = 0; k < NUM_MAX_PARTICLE_PER_CELL && k + bucketStart < numParticles; k++)
				{
					int gridAddress2 = sortedCellId[bucketStart + k];
					if (gridAddress2 != gridAddress) { break; }
					int j = sortedParticleId[bucketStart + k];
					if (i != j && phases[j] < 0)
					{
						float3 pj = positions[j];
						vnew += (velocities[j] - vi) * poly6Kernel(length2(pi - pj));
					}
				}
			}

	newVelocities[i] = velocities[i] + c * vnew;
}

__global__ void fluidNormal(float3 * __restrict__ normals,
							const float3 * __restrict__ positions,
							const float * __restrict__ densities,
							const int * __restrict__ phases,
							const int* __restrict__ sortedCellId,
							const int* __restrict__ sortedParticleId,
							const int* __restrict__ cellStart,
							const float3 cellOrigin,
							const float3 cellSize,
							const int3 gridSize,
							const int3 gridSearchOffset,
							const int numParticles)
{
	int i = threadIdx.x + __mul24(blockIdx.x, blockDim.x);
	if (i >= numParticles || phases[i] > 0) { return; }

	float3 pi = positions[i];
	int3 centerGridPos = calcGridPos(pi, cellOrigin, cellSize);
	int3 start = centerGridPos - gridSearchOffset;
	int3 end = centerGridPos + gridSearchOffset;

	float3 normal = make_float3(0.f);

	for (int z = start.z; z <= end.z; z++)
		for (int y = start.y; y <= end.y; y++)
			for (int x = start.x; x <= end.x; x++)
			{
				int3 gridPos = make_int3(x, y, z);
				int gridAddress = calcGridAddress(gridPos, gridSize);
				int bucketStart = cellStart[gridAddress];
				if (bucketStart == -1) { continue; }

				for (int k = 0; k < NUM_MAX_PARTICLE_PER_CELL && k + bucketStart < numParticles; k++)
				{
					int gridAddress2 = sortedCellId[bucketStart + k];
					if (gridAddress2 != gridAddress) { break; }
					int j = sortedParticleId[bucketStart + k];
					if (i != j && phases[j] < 0)
					{
						float3 pj = positions[j];
						float3 diff = pi - pj;
						normal += 1.0f / densities[j] * gradientSpikyKernel(diff, length2(diff));
					}
				}
			}

	normals[i] = KernelRadius * normal;
}

__global__ void fluidAkinciTension(float3 * __restrict__ newVelocities,
								   const float3 * __restrict__ velocities,
								   const float3 * __restrict__ positions,
								   const float3 * __restrict__ normals,
								   const float * __restrict__ densities,
								   const float restDensity,
								   const int * __restrict__ phases,
								   const float surfaceTension,
								   const int* __restrict__ sortedCellId,
								   const int* __restrict__ sortedParticleId,
								   const int* __restrict__ cellStart,
								   const float3 cellOrigin,
								   const float3 cellSize,
								   const int3 gridSize,
								   const int3 gridSearchOffset,
								   const int numParticles,
								   const float deltaTime)
{
	int i = threadIdx.x + __mul24(blockIdx.x, blockDim.x);
	if (i >= numParticles || phases[i] > 0) { return; }

	float3 pi = positions[i];
	int3 centerGridPos = calcGridPos(pi, cellOrigin, cellSize);
	int3 start = centerGridPos - gridSearchOffset;
	int3 end = centerGridPos + gridSearchOffset;

	float3 fTension = make_float3(0.f);

	for (int z = start.z; z <= end.z; z++)
		for (int y = start.y; y <= end.y; y++)
			for (int x = start.x; x <= end.x; x++)
			{
				int3 gridPos = make_int3(x, y, z);
				int gridAddress = calcGridAddress(gridPos, gridSize);
				int bucketStart = cellStart[gridAddress];
				if (bucketStart == -1) { continue; }

				for (int k = 0; k < NUM_MAX_PARTICLE_PER_CELL && k + bucketStart < numParticles; k++)
				{
					int gridAddress2 = sortedCellId[bucketStart + k];
					if (gridAddress2 != gridAddress) { break; }
					int j = sortedParticleId[bucketStart + k];
					if (i != j && phases[j] < 0)
					{
						float3 pj = positions[j];
						float lenPiPj = length(pi - pj);
						if (lenPiPj > 0.f)
						{
							float3 fCohesion = -surfaceTension * akinciSplineC(lenPiPj) * (pi - pj) / lenPiPj;
							float3 fCurvature = -surfaceTension * (normals[i] - normals[j]);
							float kij = 2.0f * restDensity / (densities[i] + densities[j]);
							fTension += kij * (fCohesion + fCurvature);
						}
						
					}
				}
			}

	newVelocities[i] = velocities[i] + fTension * deltaTime;
}

__global__ void updatePositions(float3 * __restrict__ positions,
								const float3 * __restrict__ newPositions,
								const int * __restrict__ phases,
								const float threshold,
								const int numParticles)
{
	int i = threadIdx.x + __mul24(blockIdx.x, blockDim.x);
	if (i >= numParticles) { return; }

	const int phase = phases[i];
	const float3 x = positions[i];
	const float3 newX = newPositions[i];

	const float dist2 = length2(newX - x);
	positions[i] = (dist2 >= threshold * threshold || phases[i] < 0) ? newX : x;
}

struct ParticleSolver
{
	ParticleSolver(const std::shared_ptr<Scene> & scene):
		scene(scene),
		cellOrigin(make_float3(-4.01, -1.01, -5.01)),
		cellSize(make_float3(scene->radius * 2.3f)),
		gridSize(make_int3(512))
	{
		fluidKernelRadius = 2.3f * scene->radius;
		SetKernelRadius(fluidKernelRadius);

		// alloc particle vars
		checkCudaErrors(cudaMalloc(&devPositions, scene->numMaxParticles * sizeof(float3)));
		checkCudaErrors(cudaMalloc(&devNewPositions, scene->numMaxParticles * sizeof(float3)));
		checkCudaErrors(cudaMalloc(&devTempFloat3, scene->numMaxParticles * sizeof(float3)));
		checkCudaErrors(cudaMalloc(&devVelocities, scene->numMaxParticles * sizeof(float3)));
		checkCudaErrors(cudaMalloc(&devMasses, scene->numMaxParticles * sizeof(float)));
		checkCudaErrors(cudaMalloc(&devInvMasses, scene->numMaxParticles * sizeof(float)));
		checkCudaErrors(cudaMalloc(&devInvScaledMasses, scene->numMaxParticles * sizeof(float)));
		checkCudaErrors(cudaMalloc(&devPhases, scene->numMaxParticles * sizeof(int)));
		checkCudaErrors(cudaMalloc(&devOmegas, scene->numMaxParticles * sizeof(float3)));

		// set velocity
		checkCudaErrors(cudaMemset(devVelocities, 0, scene->numMaxParticles * sizeof(float3)));

		// alloc rigid body
		checkCudaErrors(cudaMalloc(&devRigidBodyParticleIdRange, scene->numMaxRigidBodies * sizeof(int2)));
		checkCudaErrors(cudaMalloc(&devRigidBodyCMs, scene->numMaxRigidBodies * sizeof(float3)));
		checkCudaErrors(cudaMalloc(&devRigidBodyInitialPositions, scene->numMaxRigidBodies * NUM_MAX_PARTICLE_PER_RIGID_BODY * sizeof(float3)));
		checkCudaErrors(cudaMalloc(&devRigidBodyRotations, scene->numMaxRigidBodies * sizeof(quaternion)));
		int numBlocksRigidBody, numThreadsRigidBody;
		GetNumBlocksNumThreads(&numBlocksRigidBody, &numThreadsRigidBody, scene->numMaxRigidBodies);
		setDevArr_float4<<<numBlocksRigidBody, numThreadsRigidBody>>>(devRigidBodyRotations, make_float4(0, 0, 0, 1), scene->numMaxRigidBodies);

		// alloc and set phase counter
		checkCudaErrors(cudaMalloc(&devSolidPhaseCounter, sizeof(int)));
		checkCudaErrors(cudaMemset(devSolidPhaseCounter, 1, sizeof(int)));

		// alloc grid accel
		checkCudaErrors(cudaMalloc(&devCellId, scene->numMaxParticles * sizeof(int)));
		checkCudaErrors(cudaMalloc(&devParticleId, scene->numMaxParticles * sizeof(int)));
		checkCudaErrors(cudaMalloc(&devSortedCellId, scene->numMaxParticles * sizeof(int)));
		checkCudaErrors(cudaMalloc(&devSortedParticleId, scene->numMaxParticles * sizeof(int)));
		checkCudaErrors(cudaMalloc(&devCellStart, gridSize.x * gridSize.y * gridSize.z * sizeof(int)));

		// alloc fluid vars
		checkCudaErrors(cudaMalloc(&devFluidLambdas, scene->numMaxParticles * sizeof(float)));
		checkCudaErrors(cudaMalloc(&devFluidDensities, scene->numMaxParticles * sizeof(float)));
		checkCudaErrors(cudaMalloc(&devFluidNormals, scene->numMaxParticles * sizeof(float3)));

		// start initing the scene
		for (std::shared_ptr<RigidBody> rigidBody : scene->rigidBodies)
		{
			addRigidBody(rigidBody->positions, rigidBody->positions_CM_Origin, rigidBody->massPerParticle);
		}

		for (std::shared_ptr<Granulars> granulars : scene->granulars)
		{
			addGranulars(granulars->positions, granulars->massPerParticle);
		}

		for (std::shared_ptr<Fluid> fluids : scene->fluids)
		{
			addFluids(fluids->positions, fluids->massPerParticle);
		}

		fluidRestDensity = scene->fluidRestDensity;
	}

	void updateTempStorageSize(const size_t size)
	{
		if (size > devTempStorageSize)
		{
			if (devTempStorage != nullptr) { checkCudaErrors(cudaFree(devTempStorage)); }
			checkCudaErrors(cudaMalloc(&devTempStorage, size));
			devTempStorageSize = size;
		}
	}

	glm::vec3 getParticlePosition(const int particleIndex)
	{
		if (particleIndex < 0 || particleIndex >= scene->numParticles) return glm::vec3(0.0f);
		float3 * tmp = (float3 *)malloc(sizeof(float3));
		cudaMemcpy(tmp, devPositions + particleIndex, sizeof(float3), cudaMemcpyDeviceToHost);
		glm::vec3 result(tmp->x, tmp->y, tmp->z);
		free(tmp);
		return result;
	}

	void setParticle(const int particleIndex, const glm::vec3 & position, const glm::vec3 & velocity)
	{
		if (particleIndex < 0 || particleIndex >= scene->numParticles) return;
		setDevArr_float3<<<1, 1>>>(devPositions + particleIndex, make_float3(position.x, position.y, position.z), 1);
		setDevArr_float3<<<1, 1>>>(devVelocities + particleIndex, make_float3(velocity.x, velocity.y, velocity.z), 1);
	}

	void addGranulars(const std::vector<glm::vec3> & positions, const float massPerParticle)
	{
		int numParticles = positions.size();
		if (scene->numParticles + numParticles >= scene->numMaxParticles)
		{
			std::string message = std::string(__FILE__) + std::string("num particles exceed num max particles");
			throw std::exception(message.c_str());
		}

		int numBlocks, numThreads;
		GetNumBlocksNumThreads(&numBlocks, &numThreads, numParticles);

		// set positions
		checkCudaErrors(cudaMemcpy(devPositions + scene->numParticles,
								   &(positions[0].x),
								   numParticles * sizeof(float) * 3,
								   cudaMemcpyHostToDevice));
		// set masses
		setDevArr_float<<<numBlocks, numThreads>>>(devMasses + scene->numParticles,
												   massPerParticle,
												   numParticles);	
		// set invmasses
		setDevArr_float<<<numBlocks, numThreads>>>(devInvMasses + scene->numParticles,
												   1.0f / massPerParticle,
												   numParticles);
		// set phases
		setDevArr_counterIncrement<<<numBlocks, numThreads>>>(devPhases + scene->numParticles,
															  devSolidPhaseCounter,
															  1,
															  numParticles);
		scene->numParticles += numParticles;
	}

	void addRigidBody(const std::vector<glm::vec3> & initialPositions, const std::vector<glm::vec3> & initialPositions_CM_Origin, const float massPerParticle)
	{
		int numParticles = initialPositions.size();
		if (scene->numParticles + numParticles >= scene->numMaxParticles)
		{
			std::string message = std::string(__FILE__) + std::string("num particles exceed num max particles");
			throw std::exception(message.c_str());
		}

		if (scene->numRigidBodies + 1 >= scene->numMaxRigidBodies)
		{
			std::string message = std::string(__FILE__) + std::string("num rigid bodies exceed num max rigid bodies");
			throw std::exception(message.c_str());
		}

		glm::vec3 cm = glm::vec3(0.0f);
		for (const glm::vec3 & position : initialPositions_CM_Origin) { cm += position; }
		cm /= (float)initialPositions_CM_Origin.size();

		if (glm::length(cm) >= 1e-5f)
		{
			std::string message = std::string(__FILE__) + std::string("expected Center of Mass at the origin");
			throw std::exception(message.c_str());
		}

		// set positions
		checkCudaErrors(cudaMemcpy(devPositions + scene->numParticles,
								   &(initialPositions[0].x),
								   numParticles * sizeof(float) * 3,
								   cudaMemcpyHostToDevice));
		checkCudaErrors(cudaMemcpy(devRigidBodyInitialPositions + scene->numParticles,
								   &(initialPositions_CM_Origin[0].x),
								   numParticles * sizeof(float) * 3,
								   cudaMemcpyHostToDevice));
		int numBlocks, numThreads;
		GetNumBlocksNumThreads(&numBlocks, &numThreads, numParticles);

		// set masses
		setDevArr_float<<<numBlocks, numThreads>>>(devMasses + scene->numParticles,
												   massPerParticle,
												   numParticles);

		// set inv masses
		setDevArr_float<<<numBlocks, numThreads>>>(devInvMasses + scene->numParticles,
												   1.0f / massPerParticle,
												   numParticles);
		// set phases
		setDevArr_devIntPtr<<<numBlocks, numThreads>>>(devPhases + scene->numParticles,
													   devSolidPhaseCounter,
													   numParticles);
		// set range for particle id
		setDevArr_int2<<<1, 1>>>(devRigidBodyParticleIdRange + scene->numRigidBodies,
								 make_int2(scene->numParticles, scene->numParticles + numParticles),
								 1);
		// increment phase counter
		increment<<<1, 1>>>(devSolidPhaseCounter);
		
		scene->numParticles += numParticles;
		scene->numRigidBodies += 1;
	}

	void addFluids(const std::vector<glm::vec3> & positions, const float massPerParticle)
	{
		int numParticles = positions.size();
		if (scene->numParticles + numParticles >= scene->numMaxParticles)
		{
			std::string message = std::string(__FILE__) + std::string("num particles exceed num max particles");
			throw std::exception(message.c_str());
		}

		int numBlocks, numThreads;
		GetNumBlocksNumThreads(&numBlocks, &numThreads, numParticles);

		// set positions
		checkCudaErrors(cudaMemcpy(devPositions + scene->numParticles,
								   &(positions[0].x),
								   numParticles * sizeof(float) * 3,
								   cudaMemcpyHostToDevice));
		// set masses
		setDevArr_float<<<numBlocks, numThreads>>>(devMasses + scene->numParticles,
												   massPerParticle,
												   numParticles);	
		// set invmasses
		setDevArr_float<<<numBlocks, numThreads>>>(devInvMasses + scene->numParticles,
												   1.0f / massPerParticle,
												   numParticles);
		// fluid phase is always -1
		setDevArr_int<<<numBlocks, numThreads>>>(devPhases + scene->numParticles,
												 -1,
												 numParticles);
		scene->numParticles += numParticles;
	}

	void updateGrid(int numBlocks, int numThreads)
	{
		setDevArr_int<<<numBlocks, numThreads>>>(devCellStart, -1, scene->numMaxParticles);
		updateGridId<<<numBlocks, numThreads>>>(devCellId,
												devParticleId,
												devNewPositions,
												cellOrigin,
												cellSize,
												gridSize,
												scene->numParticles);
		size_t tempStorageSize = 0;
		// get temp storage size (not sorting yet)
		cub::DeviceRadixSort::SortPairs(NULL,
										tempStorageSize,
										devCellId,
										devSortedCellId,
										devParticleId,
										devSortedParticleId,
										scene->numParticles);
		updateTempStorageSize(tempStorageSize);
		// sort!
		cub::DeviceRadixSort::SortPairs(devTempStorage,
										devTempStorageSize,
										devCellId,
										devSortedCellId,
										devParticleId,
										devSortedParticleId,
										scene->numParticles);
		findStartId<<<numBlocks, numThreads>>>(devCellStart, devSortedCellId, scene->numParticles);
	}

	void update(const int numSubTimeStep,
				const float deltaTime,
				const int pickedParticleId = -1,
				const glm::vec3 & pickedParticlePosition = glm::vec3(0.0f),
				const glm::vec3 & pickedParticleVelocity = glm::vec3(0.0f))
	{
		float subDeltaTime = deltaTime / (float)numSubTimeStep;
		int numBlocks, numThreads;
		GetNumBlocksNumThreads(&numBlocks, &numThreads, scene->numParticles);

		int3 fluidGridSearchOffset = make_int3(ceil(make_float3(fluidKernelRadius) / cellSize));
		bool useAkinciCohesionTension = true;

		for (int i = 0;i < numSubTimeStep;i++)
		{ 
			applyForces<<<numBlocks, numThreads>>>(devVelocities,
												   devInvMasses,
												   scene->numParticles,
												   subDeltaTime);

			// we need to make picked particle immovable
			if (pickedParticleId >= 0 && pickedParticleId < scene->numParticles)
			{
				setParticle(pickedParticleId, pickedParticlePosition, glm::vec3(0.0f));
			}

			predictPositions<<<numBlocks, numThreads>>>(devNewPositions,
														devPositions,
														devVelocities,
														scene->numParticles,
														subDeltaTime);


			// compute scaled masses
			computeInvScaledMasses<<<numBlocks, numThreads>>>(devInvScaledMasses,
															  devMasses,
															  devPositions,
															  MASS_SCALING_CONSTANT,
															  scene->numParticles);

			// stabilize iterations
			for (int i = 0; i < 2; i++)
			{
				for (const Plane & plane : scene->planes)
				{
					planeStabilize<<<numBlocks, numThreads>>>(devPositions,
															  devNewPositions,
															  scene->numParticles,
															  make_float3(plane.origin),
															  make_float3(plane.normal),
															  scene->radius);
				}
			}

			// projecting constraints iterations
			// (update grid every n iterations)
			for (int i = 0; i < 1; i++)
			{
				// compute grid
				updateGrid(numBlocks, numThreads);

				for (int j = 0; j < 2; j++)
				{
					// solving all plane collisions
					for (const Plane & plane : scene->planes)
					{
						particlePlaneCollisionConstraint<<<numBlocks, numThreads>>>(devNewPositions,
																					devPositions,
																					scene->numParticles,
																					make_float3(plane.origin),
																					make_float3(plane.normal),
																					scene->radius);
					}

					/*// solving all particles collisions
					particleParticleCollisionConstraint<<<numBlocks, numThreads>>>(devTempNewPositions,
																				   devNewPositions,
																				   devPositions,
																				   devInvScaledMasses,
																				   devPhases,
																				   devSortedCellId,
																				   devSortedParticleId,
																				   devCellStart,
																				   cellOrigin,
																				   cellSize,
																				   gridSize,
																				   scene->numParticles,
																				   scene->radius);*/
					//std::swap(devTempNewPositions, devNewPositions);

					// fluid
					fluidLambda<<<numBlocks, numThreads>>>(devFluidLambdas,
														   devFluidDensities,
														   devNewPositions,
														   devMasses,
														   devPhases,
														   fluidRestDensity,
														   300.0f, // relaxation parameter
														   devSortedCellId,
														   devSortedParticleId,
														   devCellStart,
														   cellOrigin,
														   cellSize,
														   gridSize,
														   fluidGridSearchOffset,
														   scene->numParticles,
														   useAkinciCohesionTension);
					fluidPosition<<<numBlocks, numThreads>>>(devTempFloat3,
															 devNewPositions,
															 devFluidLambdas,
															 fluidRestDensity,
															 devPhases,
															 0.0001f, // k for sCorr
															 4, // N for sCorr
															 devSortedCellId,
															 devSortedParticleId,
															 devCellStart,
															 cellOrigin,
															 cellSize,
															 gridSize,
															 fluidGridSearchOffset,
															 scene->numParticles,
															 useAkinciCohesionTension);
					std::swap(devTempFloat3, devNewPositions);

					// solve all rigidbody constraints
					if (scene->numRigidBodies > 0)
					{ 
						shapeMatchingAlphaOne<<<scene->numRigidBodies, NUM_MAX_PARTICLE_PER_RIGID_BODY>>>(devRigidBodyRotations,
																										  devRigidBodyCMs,
																										  devNewPositions,
																										  devRigidBodyInitialPositions,
																										  devRigidBodyParticleIdRange);
					}
				}
			}

			updateVelocity<<<numBlocks, numThreads>>>(devVelocities,
													  devNewPositions,
													  devPositions,
													  scene->numParticles,
													  1.0f / subDeltaTime);

			updatePositions<<<numBlocks, numThreads>>>(devPositions, devNewPositions, devPhases, PARTICLE_SLEEPING_EPSILON, scene->numParticles);

			// vorticity confinement part 1.
			fluidOmega<<<numBlocks, numThreads>>>(devOmegas,
												  devVelocities,
												  devNewPositions,
												  devPhases,
												  devSortedCellId,
												  devSortedParticleId,
												  devCellStart,
												  cellOrigin,
												  cellSize,
												  gridSize,
												  fluidGridSearchOffset,
												  scene->numParticles);

			// vorticity confinement part 2.
			fluidVorticity<<<numBlocks, numThreads>>>(devVelocities,
													  devOmegas,
													  devNewPositions,
													  0.001f, // epsilon in eq. 16
													  devPhases,
													  devSortedCellId,
													  devSortedParticleId,
													  devCellStart,
													  cellOrigin,
													  cellSize,
													  gridSize,
													  fluidGridSearchOffset,
													  scene->numParticles,
													  subDeltaTime);

			if (useAkinciCohesionTension)
			{ 
				// fluid normal for Akinci cohesion
				fluidNormal<<<numBlocks, numThreads>>>(devFluidNormals,
													   devNewPositions,
													   devFluidDensities,
													   devPhases,
													   devSortedCellId,
													   devSortedParticleId,
													   devCellStart,
													   cellOrigin,
													   cellSize,
													   gridSize,
													   fluidGridSearchOffset,
													   scene->numParticles);

				fluidAkinciTension<<<numBlocks, numThreads>>>(devTempFloat3,
															  devVelocities,
															  devNewPositions,
															  devFluidNormals,
															  devFluidDensities,
															  fluidRestDensity,
															  devPhases,
															  0.6, // tension strength
															  devSortedCellId,
															  devSortedParticleId,
															  devCellStart,
															  cellOrigin,
															  cellSize,
															  gridSize,
															  fluidGridSearchOffset,
															  scene->numParticles,
															  deltaTime);
				std::swap(devVelocities, devTempFloat3);
			}

			// xsph
			fluidXSph<<<numBlocks, numThreads>>>(devTempFloat3,
												 devVelocities,
												 devNewPositions,
												 0.0002f, // C in eq. 17
												 devPhases,
												 devSortedCellId,
												 devSortedParticleId,
												 devCellStart,
												 cellOrigin,
												 cellSize,
												 gridSize,
												 fluidGridSearchOffset,
												 scene->numParticles);
			std::swap(devVelocities, devTempFloat3);
		}

		// we need to make picked particle immovable
		if (pickedParticleId >= 0 && pickedParticleId < scene->numParticles)
		{
			glm::vec3 solvedPickedParticlePosition = getParticlePosition(pickedParticleId);
			setParticle(pickedParticleId, solvedPickedParticlePosition, pickedParticleVelocity);
		}
	}

	/// TODO:: implement object's destroyer

	float3 *	devPositions;
	float3 *	devNewPositions;
	float3 *	devTempFloat3;
	float3 *	devVelocities;
	float *		devMasses;
	float *		devInvMasses;
	float *		devInvScaledMasses;
	int *		devPhases;
	int *		devSolidPhaseCounter;
	float3 *	devOmegas;

	float *		devFluidLambdas;
	float *		devFluidDensities;
	float3 *	devFluidNormals;
	int *		devFluidNeighboursIds;
	float		fluidKernelRadius;
	float		fluidRestDensity;

	int *		devSortedCellId;
	int *		devSortedParticleId;

	int2 *		devRigidBodyParticleIdRange;
	float3 *	devRigidBodyInitialPositions;
	quaternion * devRigidBodyRotations;
	float3 *	devRigidBodyCMs;// center of mass

	void *		devTempStorage = nullptr;
	size_t		devTempStorageSize = 0;

	int *			devCellId;
	int *			devParticleId;
	int *			devCellStart;
	const float3	cellOrigin;
	const float3	cellSize;
	const int3		gridSize;

	std::shared_ptr<Scene> scene;
};