#include <cstdio>
#include <cuda.h>
#include <cmath>
#include <thrust/execution_policy.h>
#include <thrust/random.h>
#include <thrust/remove.h>

#include "sceneStructs.h"
#include "scene.h"
#include "glm/glm.hpp"
#include "glm/gtx/norm.hpp"
#include "glm/gtc/matrix_inverse.hpp"
#include "utilities.h"
#include "pathtrace.h"
#include "intersections.h"
#include "interactions.h"

#define ERRORCHECK 1
#define FAKE 0
#define CACHE 0
#define SORT 0
#define ANTIALIASING 1
#define DOF 1
#define DIRECTLIGHT	0
#define MOTION 0
#define TIMER 1

#define lenRadius 0.3f
#define focalDistance 3.0f

#define FILENAME (strrchr(__FILE__, '/') ? strrchr(__FILE__, '/') + 1 : __FILE__)
#define checkCUDAError(msg) checkCUDAErrorFn(msg, FILENAME, __LINE__)
void checkCUDAErrorFn(const char *msg, const char *file, int line) {
#if ERRORCHECK
    cudaDeviceSynchronize();
    cudaError_t err = cudaGetLastError();
    if (cudaSuccess == err) {
        return;
    }

    fprintf(stderr, "CUDA error");
    if (file) {
        fprintf(stderr, " (%s:%d)", file, line);
    }
    fprintf(stderr, ": %s: %s\n", msg, cudaGetErrorString(err));
#  ifdef _WIN32
    getchar();
#  endif
    exit(EXIT_FAILURE);
#endif
}

PerformanceTimer& timer()
{
	static PerformanceTimer timer;
	return timer;
}


__host__ __device__
thrust::default_random_engine makeSeededRandomEngine(int iter, int index, int depth) {
    int h = utilhash((1 << 31) | (depth << 22) | iter) ^ utilhash(index);
    return thrust::default_random_engine(h);
}

//Kernel that writes the image to the OpenGL PBO directly.
__global__ void sendImageToPBO(uchar4* pbo, glm::ivec2 resolution,
        int iter, glm::vec3* image) {
    int x = (blockIdx.x * blockDim.x) + threadIdx.x;
    int y = (blockIdx.y * blockDim.y) + threadIdx.y;

    if (x < resolution.x && y < resolution.y) {
        int index = x + (y * resolution.x);
        glm::vec3 pix = image[index];

        glm::ivec3 color;
        color.x = glm::clamp((int) (pix.x / iter * 255.0), 0, 255);
        color.y = glm::clamp((int) (pix.y / iter * 255.0), 0, 255);
        color.z = glm::clamp((int) (pix.z / iter * 255.0), 0, 255);

        // Each thread writes one pixel location in the texture (textel)
        pbo[index].w = 0;
        pbo[index].x = color.x;
        pbo[index].y = color.y;
        pbo[index].z = color.z;
    }
}

static Scene * hst_scene = NULL;
static glm::vec3 * dev_image = NULL;
static Geom * dev_geoms = NULL;
static Material * dev_materials = NULL;
static PathSegment * dev_paths = NULL;
static ShadeableIntersection * dev_intersections = NULL;
// TODO: static variables for device memory, any extra info you need, etc
// ...
static ShadeableIntersection * dev_firstIntersects = NULL;
static Light * dev_lights = NULL;


void pathtraceInit(Scene *scene) {
    hst_scene = scene;
    const Camera &cam = hst_scene->state.camera;
    const int pixelcount = cam.resolution.x * cam.resolution.y;

    cudaMalloc(&dev_image, pixelcount * sizeof(glm::vec3));
    cudaMemset(dev_image, 0, pixelcount * sizeof(glm::vec3));

  	cudaMalloc(&dev_paths, pixelcount * sizeof(PathSegment));

  	cudaMalloc(&dev_geoms, scene->geoms.size() * sizeof(Geom));
  	cudaMemcpy(dev_geoms, scene->geoms.data(), scene->geoms.size() * sizeof(Geom), cudaMemcpyHostToDevice);

  	cudaMalloc(&dev_materials, scene->materials.size() * sizeof(Material));
  	cudaMemcpy(dev_materials, scene->materials.data(), scene->materials.size() * sizeof(Material), cudaMemcpyHostToDevice);

  	cudaMalloc(&dev_intersections, pixelcount * sizeof(ShadeableIntersection));
  	cudaMemset(dev_intersections, 0, pixelcount * sizeof(ShadeableIntersection));

    // TODO: initialize any extra device memeory you need
	cudaMalloc(&dev_firstIntersects, pixelcount * sizeof(ShadeableIntersection));
	cudaMemset(dev_firstIntersects, 0, pixelcount * sizeof(ShadeableIntersection));

	cudaMalloc(&dev_lights, scene->lights.size() * sizeof(Light));
	cudaMemcpy(dev_lights, scene->lights.data(), scene->lights.size() * sizeof(Light), cudaMemcpyHostToDevice);

    checkCUDAError("pathtraceInit");
}

void pathtraceFree() {
    cudaFree(dev_image);  // no-op if dev_image is null
  	cudaFree(dev_paths);
  	cudaFree(dev_geoms);
  	cudaFree(dev_materials);
  	cudaFree(dev_intersections);
	
    // TODO: clean up any extra device memory you created
	cudaFree(dev_firstIntersects);
	cudaFree(dev_lights);

    checkCUDAError("pathtraceFree");
}

/**
* Generate PathSegments with rays from the camera through the screen into the
* scene, which is the first bounce of rays.
*
* Antialiasing - add rays for sub-pixel sampling
* motion blur - jitter rays "in time"
* lens effect - jitter ray origin positions based on a lens
*/
__global__ void generateRayFromCamera(Camera cam, int iter, int traceDepth, PathSegment* pathSegments)
{
	int x = (blockIdx.x * blockDim.x) + threadIdx.x;
	int y = (blockIdx.y * blockDim.y) + threadIdx.y;

	if (x < cam.resolution.x && y < cam.resolution.y) {
		int index = x + (y * cam.resolution.x);
		PathSegment & segment = pathSegments[index];

		segment.ray.origin = cam.position;
		segment.color = glm::vec3(1.0f, 1.0f, 1.0f);

		// TODO: implement antialiasing by jittering the ray
		thrust::default_random_engine rng = makeSeededRandomEngine(iter, index, 0);
		thrust::uniform_real_distribution<float> u01(0, 1);
#if ANTIALIASING
		float xJitter = u01(rng);
		float yJitter = u01(rng);
		segment.ray.direction = glm::normalize(cam.view
			- cam.right * cam.pixelLength.x * ((float)x + xJitter - (float)cam.resolution.x * 0.5f)
			- cam.up * cam.pixelLength.y * ((float)y + yJitter - (float)cam.resolution.y * 0.5f)
		);
#else
		segment.ray.direction = glm::normalize(cam.view
			- cam.right * cam.pixelLength.x * ((float)x - (float)cam.resolution.x * 0.5f)
			- cam.up * cam.pixelLength.y * ((float)y - (float)cam.resolution.y * 0.5f)
		);
#endif
#if DOF
		if (lenRadius > 0) {
			glm::vec2 pLens = (float)lenRadius * ConcentricSampleDisk(glm::vec2(u01(rng), u01(rng)));
			float ft = glm::abs(focalDistance / segment.ray.direction.z);
			glm::vec3 pFocus = segment.ray.origin + ft * segment.ray.direction;
			segment.ray.origin += cam.right * pLens.x + cam.up * pLens.y;
			segment.ray.direction = glm::normalize(pFocus - segment.ray.origin);
		}
#endif


		segment.pixelIndex = index;
		segment.remainingBounces = traceDepth;
	}
}

// TODO:
// computeIntersections handles generating ray intersections ONLY.
// Generating new rays is handled in your shader(s).
// Feel free to modify the code below.
__global__ void computeIntersections(
	int depth
	, int num_paths
	, PathSegment * pathSegments
	, Geom * geoms
	, int geoms_size
	, ShadeableIntersection * intersections
	)
{
	int path_index = blockIdx.x * blockDim.x + threadIdx.x;

	if (path_index < num_paths)
	{
		PathSegment pathSegment = pathSegments[path_index];

		float t;
		glm::vec3 intersect_point;
		glm::vec3 normal;
		float t_min = FLT_MAX;
		int hit_geom_index = -1;
		bool outside = true;

		glm::vec3 tmp_intersect;
		glm::vec3 tmp_normal;

		// naive parse through global geoms

		for (int i = 0; i < geoms_size; i++)
		{
			Geom & geom = geoms[i];

			if (geom.type == CUBE)
			{
				t = boxIntersectionTest(geom, pathSegment.ray, tmp_intersect, tmp_normal, outside);
			}
			else if (geom.type == SPHERE)
			{
				t = sphereIntersectionTest(geom, pathSegment.ray, tmp_intersect, tmp_normal, outside);
			}
			// TODO: add more intersection tests here... triangle? metaball? CSG?

			// Compute the minimum t from the intersection tests to determine what
			// scene geometry object was hit first.
			if (t > 0.0f && t_min > t)
			{
				t_min = t;
				hit_geom_index = i;
				intersect_point = tmp_intersect;
				normal = tmp_normal;
			}
		}

		if (hit_geom_index == -1)
		{
			intersections[path_index].t = -1.0f;
		}
		else
		{
			//The ray hits something
			intersections[path_index].t = t_min;
			intersections[path_index].materialId = geoms[hit_geom_index].materialid;
			intersections[path_index].surfaceNormal = normal;
			intersections[path_index].position = intersect_point;
		}
	}
}

// LOOK: "fake" shader demonstrating what you might do with the info in
// a ShadeableIntersection, as well as how to use thrust's random number
// generator. Observe that since the thrust random number generator basically
// adds "noise" to the iteration, the image should start off noisy and get
// cleaner as more iterations are computed.
//
// Note that this shader does NOT do a BSDF evaluation!
// Your shaders should handle that - this can allow techniques such as
// bump mapping.
__global__ void shadeFakeMaterial (
	int iter
	, int num_paths
	, ShadeableIntersection * shadeableIntersections
	, PathSegment * pathSegments
	, Material * materials)
{
  int idx = blockIdx.x * blockDim.x + threadIdx.x;
  if (idx < num_paths)
  {
    ShadeableIntersection intersection = shadeableIntersections[idx];
    if (intersection.t > 0.0f) { // if the intersection exists...
      // Set up the RNG
      // LOOK: this is how you use thrust's RNG! Please look at
      // makeSeededRandomEngine as well.
      thrust::default_random_engine rng = makeSeededRandomEngine(iter, idx, 0);
      thrust::uniform_real_distribution<float> u01(0, 1);

      Material material = materials[intersection.materialId];
      glm::vec3 materialColor = material.color;

      // If the material indicates that the object was a light, "light" the ray
      if (material.emittance > 0.0f) {
        pathSegments[idx].color *= (materialColor * material.emittance);
      }
      // Otherwise, do some pseudo-lighting computation. This is actually more
      // like what you would expect from shading in a rasterizer like OpenGL.
      // TODO: replace this! you should be able to start with basically a one-liner
      else {
        float lightTerm = glm::dot(intersection.surfaceNormal, glm::vec3(0.0f, 1.0f, 0.0f));
        pathSegments[idx].color *= (materialColor * lightTerm) * 0.3f + ((1.0f - intersection.t * 0.02f) * materialColor) * 0.7f;
        pathSegments[idx].color *= u01(rng); // apply some noise because why not
      }
    // If there was no intersection, color the ray black.
    // Lots of renderers use 4 channel color, RGBA, where A = alpha, often
    // used for opacity, in which case they can indicate "no opacity".
    // This can be useful for post-processing and image compositing.
    } else {
      pathSegments[idx].color = glm::vec3(0.0f);
    }
  }
}
//************************* Direct Lighting *******************************

__device__ glm::vec3 sampleOnLight(
	glm::vec2 xi,
	const Geom& geom)
{
	glm::vec4 localP;
	if (geom.type == CUBE) {
		localP = glm::vec4(xi.x - 0.5f, -0.5f, xi.y - 0.5f, 1.0f);
		
	}
	else if (geom.type == SPHERE) {
		localP = glm::vec4(squareToSphereUniform(xi), 1.0f);
	}

	glm::vec3 worldP = glm::vec3(geom.transform * localP);
	return worldP;
}


__device__ glm::vec3 directLight(
	int num_lights,
	int num_geoms,
	glm::vec3 intersect,
	glm::vec3 normal,
	Light* dev_lights,
	Geom* dev_geoms,
	Material* materials,
	thrust::default_random_engine &rng)
{
	// random select one light
	thrust::uniform_real_distribution<float> u01(0, 1);
	int lightIdx = glm::min((int)(u01(rng) * num_lights), num_lights - 1);
	Light &light = dev_lights[lightIdx];

	// sample on light
	glm::vec3 sampleP = sampleOnLight(glm::vec2(u01(rng), u01(rng)), dev_geoms[light.geomId]);
	glm::vec3 wi = glm::normalize(sampleP - intersect);
	float distance = glm::distance(sampleP, intersect);
	Ray ray;
	ray.origin = intersect + wi * 0.0001f;
	ray.direction = wi;

	// test if blocked
	for (int i = 0; i < num_geoms; i++) {
		Geom &geom = dev_geoms[i];
		float t = 0;
		bool outside;
		glm::vec3 normalt;
		if (geom.type == CUBE)
		{
			t = boxIntersectionTest(geom, ray, intersect, normalt, outside);
		}
		else if (geom.type == SPHERE)
		{
			t = sphereIntersectionTest(geom, ray, intersect, normalt, outside);
		}
		if (t > 0.0f && materials[geom.materialid].emittance < 0.0001f && t < distance) {
			return glm::vec3(0.0f);
		}

	}

	return materials[light.materialId].color * materials[light.materialId].emittance * AbsDot(wi, normal);
}
//*************************************************************************

//************************* Shading Kernal ********************************

#pragma region BSDFShading

__global__ void kernShading(
	int iter,
	int depth,
	int num_paths,
	ShadeableIntersection* shadeableIntersections,
	PathSegment* pathsegments,
	Material* materials
#if DIRECTLIGHT
	,
	int num_lights,
	int num_geoms,
	Light* lights,
	Geom* geoms
#endif
)
{
	int idx = blockDim.x * blockIdx.x + threadIdx.x;
	if (idx < num_paths) {

		ShadeableIntersection intersection = shadeableIntersections[idx];

		if (intersection.t > 0.0f) {
			thrust::default_random_engine rng = makeSeededRandomEngine(iter, idx, depth);
			//thrust::uniform_real_distribution<float> u01(0, 1);

			Material material = materials[intersection.materialId];
			glm::vec3 materialColor = material.color;

			if (material.emittance > 0.0f) {
				pathsegments[idx].color *= (materialColor * material.emittance);
				pathsegments[idx].remainingBounces = 0;
				return;
			}
			else
			{
				scatterRay(idx, pathsegments[idx], intersection.position, intersection.surfaceNormal, material, rng);
				pathsegments[idx].remainingBounces--;
				if (pathsegments[idx].remainingBounces == 0)
				{
#if DIRECTLIGHT	
					pathsegments[idx].color *= directLight(num_lights, num_geoms, intersection.position, intersection.surfaceNormal, lights, geoms, materials, rng);
#else
					pathsegments[idx].color = glm::vec3(0.0f);
#endif
				}
			}
		}
		else {
			pathsegments[idx].color = glm::vec3(0.0f);
			pathsegments[idx].remainingBounces = 0;
		}
	}
}

#pragma endregion BSDFShading

//*************************************************************************

//************************* Stream Compact ********************************
struct isRemainBouncing
{
	__host__ __device__ bool operator()(const PathSegment& path)
	{
		return path.remainingBounces == 0;
	}
};
//*************************************************************************

//***************************** Sort **************************************
struct materialSort
{
	__host__ __device__ bool operator()(const ShadeableIntersection &a, const ShadeableIntersection &b)
	{
		return a.materialId < b.materialId;
	}
};
//*************************************************************************



// Add the current iteration's output to the overall image
__global__ void finalGather(int nPaths, glm::vec3 * image, PathSegment * iterationPaths)
{
	int index = (blockIdx.x * blockDim.x) + threadIdx.x;

	if (index < nPaths)
	{
		PathSegment iterationPath = iterationPaths[index];
		if (iterationPath.remainingBounces == 0) {
			image[iterationPath.pixelIndex] += iterationPath.color;
		}
	}
}

/**
 * Wrapper for the __global__ call that sets up the kernel calls and does a ton
 * of memory management
 */
void pathtrace(uchar4 *pbo, int frame, int iter) {
    const int traceDepth = hst_scene->state.traceDepth;
    const Camera &cam = hst_scene->state.camera;
    const int pixelcount = cam.resolution.x * cam.resolution.y;

	// 2D block for generating ray from camera
    const dim3 blockSize2d(8, 8);
    const dim3 blocksPerGrid2d(
            (cam.resolution.x + blockSize2d.x - 1) / blockSize2d.x,
            (cam.resolution.y + blockSize2d.y - 1) / blockSize2d.y);

	// 1D block for path tracing
	const int blockSize1d = 128;

    ///////////////////////////////////////////////////////////////////////////

    // Recap:
    // * Initialize array of path rays (using rays that come out of the camera)
    //   * You can pass the Camera object to that kernel.
    //   * Each path ray must carry at minimum a (ray, color) pair,
    //   * where color starts as the multiplicative identity, white = (1, 1, 1).
    //   * This has already been done for you.
    // * For each depth:
    //   * Compute an intersection in the scene for each path ray.
    //     A very naive version of this has been implemented for you, but feel
    //     free to add more primitives and/or a better algorithm.
    //     Currently, intersection distance is recorded as a parametric distance,
    //     t, or a "distance along the ray." t = -1.0 indicates no intersection.
    //     * Color is attenuated (multiplied) by reflections off of any object
    //   * TODO: Stream compact away all of the terminated paths.
    //     You may use either your implementation or `thrust::remove_if` or its
    //     cousins.
    //     * Note that you can't really use a 2D kernel launch any more - switch
    //       to 1D.
    //   * TODO: Shade the rays that intersected something or didn't bottom out.
    //     That is, color the ray by performing a color computation according
    //     to the shader, then generate a new ray to continue the ray path.
    //     We recommend just updating the ray's PathSegment in place.
    //     Note that this step may come before or after stream compaction,
    //     since some shaders you write may also cause a path to terminate.
    // * Finally, add this iteration's results to the image. This has been done
    //   for you.

    // TODO: perform one iteration of path tracing
#if TIMER
	timer().startGpuTimer();
#endif

#if MOTION
	float moveSpeed = 1.0f / (float)hst_scene->state.iterations;
	for (int i = 0; i < hst_scene->geoms.size(); i++)
	{
		if (hst_scene->geoms[i].motion)
		{
			hst_scene->geoms[i].translation += glm::vec3(0.0f, 3.0f, 0.0f) * moveSpeed;
			hst_scene->geoms[i].transform = utilityCore::buildTransformationMatrix(hst_scene->geoms[i].translation, hst_scene->geoms[i].rotation, hst_scene->geoms[i].scale);
			hst_scene->geoms[i].inverseTransform = glm::inverse(hst_scene->geoms[i].transform);
			hst_scene->geoms[i].invTranspose = glm::inverseTranspose(hst_scene->geoms[i].transform);
		}
	}
	cudaMemcpy(dev_geoms, &(hst_scene->geoms)[0], hst_scene->geoms.size() * sizeof(Geom), cudaMemcpyHostToDevice);
	checkCUDAError("motion blur error");
#endif

	generateRayFromCamera << <blocksPerGrid2d, blockSize2d >> >(cam, iter, traceDepth, dev_paths);
	checkCUDAError("generate camera ray");


	int depth = 0;
	PathSegment* dev_path_end = dev_paths + pixelcount;
	int num_paths = dev_path_end - dev_paths;

	dim3 numBlocksPixels = (pixelcount + blockSize1d - 1) / blockSize1d;

	// --- PathSegment Tracing Stage ---
	// Shoot ray into scene, bounce between objects, push shading chunks

	bool iterationComplete = false;
	while (!iterationComplete) {

		// clean shading chunks
		cudaMemset(dev_intersections, 0, pixelcount * sizeof(ShadeableIntersection));

		// tracing
		dim3 numblocksPathSegmentTracing = (num_paths + blockSize1d - 1) / blockSize1d;
#if CACHE
		if (iter == 1 && depth == 0) {
			computeIntersections << <numblocksPathSegmentTracing, blockSize1d >> > (
				depth
				, num_paths
				, dev_paths
				, dev_geoms
				, hst_scene->geoms.size()
				, dev_intersections
				);
			checkCUDAError("trace one bounce");
			cudaDeviceSynchronize();
			cudaMemcpy(dev_firstIntersects, dev_intersections, pixelcount * sizeof(ShadeableIntersection), cudaMemcpyDeviceToDevice);
		}
		else if(iter != 1 && depth == 0){
			cudaMemcpy(dev_intersections, dev_firstIntersects, pixelcount * sizeof(ShadeableIntersection), cudaMemcpyDeviceToDevice);
		}
		else {
			computeIntersections << <numblocksPathSegmentTracing, blockSize1d >> > (
				depth
				, num_paths
				, dev_paths
				, dev_geoms
				, hst_scene->geoms.size()
				, dev_intersections
				);
			checkCUDAError("trace one bounce");
			cudaDeviceSynchronize();
		}
#else
		computeIntersections << <numblocksPathSegmentTracing, blockSize1d >> > (
			depth
			, num_paths
			, dev_paths
			, dev_geoms
			, hst_scene->geoms.size()
			, dev_intersections
			);
		checkCUDAError("trace one bounce");
		cudaDeviceSynchronize();
#endif
		
		depth++;

#if SORT
		thrust::sort_by_key(thrust::device, dev_intersections, dev_intersections + num_paths, dev_paths, materialSort());
#endif

		// TODO:
		// --- Shading Stage ---
		// Shade path segments based on intersections and generate new rays by
		// evaluating the BSDF.
		// Start off with just a big kernel that handles all the different
		// materials you have in the scenefile.
		// TODO: compare between directly shading the path segments and shading
		// path segments that have been reshuffled to be contiguous in memory.

#if FAKE
		shadeFakeMaterial<<<numblocksPathSegmentTracing, blockSize1d>>> (
			iter,
			num_paths,
			dev_intersections,
			dev_paths,
			dev_materials);
		iterationComplete = true; // TODO: should be based off stream compaction results.
#else
		kernShading << <numblocksPathSegmentTracing, blockSize1d >> > (
			iter,
			depth,
			num_paths,
			dev_intersections,
			dev_paths,
			dev_materials
#if DIRECTLIGHT
			,
			hst_scene->lights.size(),
			hst_scene->geoms.size(),
			dev_lights,
			dev_geoms
#endif
			);
		checkCUDAError("kern Shading error");

		finalGather << <numBlocksPixels, blockSize1d >> >(num_paths, dev_image, dev_paths);

		if (depth == traceDepth) {
			iterationComplete = true;
		}

		dev_path_end = thrust::remove_if(thrust::device, dev_paths, dev_paths + num_paths, isRemainBouncing());
		num_paths = dev_path_end - dev_paths;
		if (num_paths == 0) {
			iterationComplete = true;
		}

#endif
	}

#if TIMER
	timer().endGpuTimer();
#endif



    ///////////////////////////////////////////////////////////////////////////

    // Send results to OpenGL buffer for rendering
    sendImageToPBO<<<blocksPerGrid2d, blockSize2d>>>(pbo, cam.resolution, iter, dev_image);

    // Retrieve image from GPU
    cudaMemcpy(hst_scene->state.image.data(), dev_image,
            pixelcount * sizeof(glm::vec3), cudaMemcpyDeviceToHost);

    checkCUDAError("pathtrace");

}
