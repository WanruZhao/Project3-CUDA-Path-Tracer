#pragma once

#include "intersections.h"


__device__ const float Pi = 3.14159265358979323846;
__device__ const float TwoPi = 6.28318530717958647692;
__device__ const float InvPi = 0.31830988618379067154;
__device__ const float Inv2Pi = 0.15915494309189533577;
__device__ const float Inv4Pi = 0.07957747154594766788;
__device__ const float PiOver2 = 1.57079632679489661923;
__device__ const float PiOver4 = 0.78539816339744830961;
__device__ const float Sqrt2 = 1.41421356237309504880;
__device__ const float RayEpsilon = 0.000005f;
__device__ const float FloatEpsilon = 0.000002f;

// CHECKITOUT
/**
 * Computes a cosine-weighted random direction in a hemisphere.
 * Used for diffuse lighting.
 */
__host__ __device__
glm::vec3 calculateRandomDirectionInHemisphere(
        glm::vec3 normal, thrust::default_random_engine &rng) {
    thrust::uniform_real_distribution<float> u01(0, 1);

    float up = sqrt(u01(rng)); // cos(theta)
    float over = sqrt(1 - up * up); // sin(theta)
    float around = u01(rng) * TWO_PI;

    // Find a direction that is not the normal based off of whether or not the
    // normal's components are all equal to sqrt(1/3) or whether or not at
    // least one component is less than sqrt(1/3). Learned this trick from
    // Peter Kutz.

    glm::vec3 directionNotNormal;
    if (abs(normal.x) < SQRT_OF_ONE_THIRD) {
        directionNotNormal = glm::vec3(1, 0, 0);
    } else if (abs(normal.y) < SQRT_OF_ONE_THIRD) {
        directionNotNormal = glm::vec3(0, 1, 0);
    } else {
        directionNotNormal = glm::vec3(0, 0, 1);
    }

    // Use not-normal direction to generate two perpendicular directions
    glm::vec3 perpendicularDirection1 =
        glm::normalize(glm::cross(normal, directionNotNormal));
    glm::vec3 perpendicularDirection2 =
        glm::normalize(glm::cross(normal, perpendicularDirection1));

    return up * normal
        + cos(around) * over * perpendicularDirection1
        + sin(around) * over * perpendicularDirection2;
}

__host__ __device__ inline float AbsDot(const glm::vec3 &a, const glm::vec3 &b) {
	return glm::abs(glm::dot(a, b));
}

__host__ __device__ inline bool IsBlack(const glm::vec3 &a) {
	return a.x == 0.0f && a.y == 0.0f && a.z == 0.0f;
}

__host__ __device__ inline bool SameHemisphere(const glm::vec3 &w, const glm::vec3 &wp) {
	return w.z * wp.z > 0;
}

__host__ __device__ inline float AbsCosTheta(const glm::vec3 &w) {
	return std::abs(w.z);
}

__host__ __device__ inline bool fequal(float a, float b) {
	return std::abs(a - b) < FloatEpsilon;
}

__host__ __device__ void spawnRay(PathSegment &path, glm::vec3 intersection, glm::vec3 normal, glm::vec3 wi)
{
	path.ray.origin = intersection + RayEpsilon * normal;
	path.ray.direction = wi;
}

//********************************* lambertian bsdf ************************************
__host__ __device__ glm::vec3 diffuseF(const Material &mat)
{
	return mat.color * InvPi;
}

__host__ __device__ float diffusePDF(const glm::vec3 &wi, const glm::vec3 &wo)
{
	return SameHemisphere(wi, wo) ? AbsCosTheta(wi) * InvPi : 0.0f;
}

__host__ __device__ glm::vec3 diffuseSampleF(
	glm::vec3 wo,
	glm::vec3 *wi,
	glm::vec3 normal,
	float *pdf,
	const Material &m,
	thrust::default_random_engine &rng)
{
	*wi = calculateRandomDirectionInHemisphere(normal, rng);
	if (wo.z < 0.0f) wi->z *= -1;
	*pdf = diffusePDF(*wi, wo);
	return diffuseF(m);
}

__host__ __device__ void diffuse(
	PathSegment &path,
	glm::vec3 intersection,
	glm::vec3 normal,
	const Material &m,
	thrust::default_random_engine &rng)
{
	glm::vec3 f;
	glm::vec3 wi;
	float pdf = 0.0f;

	f = diffuseSampleF(-path.ray.direction, &wi, normal, &pdf, m, rng);
	if (!IsBlack(f) && !fequal(pdf, 0.0f))
	{
		float dot = AbsDot(glm::normalize(normal), glm::normalize(wi));
		path.color *= m.color * dot * f / pdf;
	}
	else {
		path.remainingBounces = 0;
		return;
	}

	spawnRay(path, intersection, normal, wi);
	path.remainingBounces--;
}

//********************************* specular brdf ************************************







//********************************* specular btdf ************************************

/**
 * Scatter a ray with some probabilities according to the material properties.
 * For example, a diffuse surface scatters in a cosine-weighted hemisphere.
 * A perfect specular surface scatters in the reflected ray direction.
 * In order to apply multiple effects to one surface, probabilistically choose
 * between them.
 * 
 * The visual effect you want is to straight-up add the diffuse and specular
 * components. You can do this in a few ways. This logic also applies to
 * combining other types of materias (such as refractive).
 * 
 * - Always take an even (50/50) split between a each effect (a diffuse bounce
 *   and a specular bounce), but divide the resulting color of either branch
 *   by its probability (0.5), to counteract the chance (0.5) of the branch
 *   being taken.
 *   - This way is inefficient, but serves as a good starting point - it
 *     converges slowly, especially for pure-diffuse or pure-specular.
 * - Pick the split based on the intensity of each material color, and divide
 *   branch result by that branch's probability (whatever probability you use).
 *
 * This method applies its changes to the Ray parameter `ray` in place.
 * It also modifies the color `color` of the ray in place.
 *
 * You may need to change the parameter list for your purposes!
 */
__host__ __device__
void scatterRay(
		PathSegment & path,
        glm::vec3 intersect,
        glm::vec3 normal,
        const Material &m,
        thrust::default_random_engine &rng) {
    // TODO: implement this.
    // A basic implementation of pure-diffuse shading will just call the
    // calculateRandomDirectionInHemisphere defined above.


	// pure diffuse
	if (fequal(m.hasReflective, 0.0f) && fequal(m.hasRefractive, 0.0f))
	{
		//diffuse(path, intersect, normal, m, rng);
		path.color *= m.color;
		return;
	}

	// mirror
	if (m.hasReflective == 1.0f && m.hasRefractive == 0.0f) 
	{
		path.remainingBounces = 0;
		return;
	}

	path.remainingBounces = 0;

}
