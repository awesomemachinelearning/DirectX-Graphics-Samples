//*********************************************************
//
// Copyright (c) Microsoft. All rights reserved.
// This code is licensed under the MIT License (MIT).
// THIS CODE IS PROVIDED *AS IS* WITHOUT WARRANTY OF
// ANY KIND, EITHER EXPRESS OR IMPLIED, INCLUDING ANY
// IMPLIED WARRANTIES OF FITNESS FOR A PARTICULAR
// PURPOSE, MERCHANTABILITY, OR NON-INFRINGEMENT.
//
//*********************************************************

#define HLSL
#include "RaytracingHlslCompat.h"
#include "RaytracingShaderHelper.hlsli"
#include "Kernels.hlsli"

Texture2D<float> g_inValues : register(t0);

Texture2D<float4> g_inNormal : register(t1);
Texture2D<float> g_inDepth : register(t2);
Texture2D<uint> g_inNormalOct : register(t3);
Texture2D<float> g_inVariance : register(t4);   // ToDo remove
Texture2D<float> g_inSmoothedVariance : register(t5);   // ToDo rename
RWTexture2D<float> g_outFilteredValues : register(u0);
RWTexture2D<float> g_outFilteredVariance : register(u1);
#if !WORKAROUND_ATROUS_VARYING_OUTPUTS 
RWTexture2D<float> g_outFilterWeightSum : register(u2);
#endif
ConstantBuffer<AtrousWaveletTransformFilterConstantBuffer> cb: register(b0);


void AddFilterContribution(
    inout float weightedValueSum, 
    inout float weightedVarianceSum, 
    inout float weightSum, 
    in float value, 
    in float stdDeviation,
    in float depth, 
    in float3 normal, 
    float obliqueness, 
    in uint row, 
    in uint col, 
    in uint2 DTid)
{
    const float valueSigma = cb.valueSigma;
    const float normalSigma = cb.normalSigma;
    const float depthSigma = cb.depthSigma;


    int2 id = int2(DTid) + (int2(row - FilterKernel::Radius, col - FilterKernel::Radius) << cb.kernelStepShift);
    if (id.x >= 0 && id.y >= 0 && id.x < cb.textureDim.x && id.y < cb.textureDim.y)
    {
        float iValue = 0.f;
        float iVariance;
        float e_x = 0;

        if (cb.outputFilteredValue)
        {
            iValue = g_inValues[id];
            iVariance = g_inSmoothedVariance[id];

            if (cb.useCalculatedVariance)
            {
                const float errorOffset = 0.005f;
                e_x = valueSigma > 0.01f ? -abs(value - iValue) / (valueSigma * stdDeviation + errorOffset) : 0;
            }
            else
            {
                e_x = valueSigma > 0.01f ? cb.kernelStepShift > 0 ? exp(-abs(value - iValue) / (valueSigma * valueSigma)) : 0 : 0;
            }
        }

        // ToDo standardize index vs id
#if COMPRES_NORMALS
        float4 normalBufValue = g_inNormal[id];
        float4 normal4 = float4(Decode(normalBufValue.xy), normalBufValue.z);
#else
        float4 normal4 = g_inNormal[id];
#endif 
        float3 iNormal = normal4.xyz;

#if PACK_NORMAL_AND_DEPTH
        float iDepth = normal4.w;
#else
        float iDepth = g_inDepth[id];
#endif
        float e_d = depthSigma > 0.01f ? -abs(depth - iDepth) * obliqueness / (depthSigma * depthSigma) : 0;

        float w_h = FilterKernel::Kernel[row][col];

        // Ref: SVGF
        float w_n = normalSigma > 0.01f ? pow(max(0, dot(normal, iNormal)), normalSigma) : 1;
        // ToDo apply exp combination where applicable 
        float w_xd = exp(e_x + e_d);        // exp(x) * exp(y) == exp(x + y)
        float w = w_h * w_n * w_xd;

        if (cb.outputFilteredValue)
        {
            weightedValueSum += w * iValue;
        }

        weightSum += w;

        // ToDo standardize cb naming
        if (cb.outputFilteredVariance)
        {
            weightedVarianceSum += w * w * iVariance;
        }
    }
}

// Atrous Wavelet Transform Cross Bilateral Filter
// Ref: Dammertz 2010, Edge-Avoiding A-Trous Wavelet Transform for Fast Global Illumination Filtering
[numthreads(AtrousWaveletTransformFilterCS::ThreadGroup::Width, AtrousWaveletTransformFilterCS::ThreadGroup::Height, 1)]
void main(uint2 DTid : SV_DispatchThreadID, uint2 Gid : SV_GroupID)
{
    // Initialize values to the current pixel / center filter kernel value.
#if COMPRES_NORMALS
    float4 normalBufValue = g_inNormal[DTid];
    float4 normal4 = float4(Decode(normalBufValue.xy), normalBufValue.z);
    float obliqueness = max(0.0001f, pow(normalBufValue.w, 10));    // ToDO review
#else
    float4 normal4 = g_inNormal[DTid];
    #if PACK_NORMAL_AND_DEPTH
        float obliqueness = 1;
    #else
        float obliqueness = max(0.0001f, pow(normal4.w, 10));
    #endif
#endif
    float3 normal = normal4.xyz;

#if PACK_NORMAL_AND_DEPTH
    float depth = normal4.w;
#else
    float depth = g_inDepth[DTid];
#endif

    float value = 0;
    if (cb.outputFilteredValue)
    {
        value = g_inValues[DTid];
    }

    float weightSum = FilterKernel::Kernel[FilterKernel::Radius][FilterKernel::Radius];
    float weightedValueSum = weightSum * value;
    float weightedVarianceSum = 0;
    float variance = 0;
    float stdDeviation = 0;
  
    if (cb.useCalculatedVariance)
    {
        variance = g_inSmoothedVariance[DTid];
        weightedVarianceSum = FilterKernel::Kernel[FilterKernel::Radius][FilterKernel::Radius] * FilterKernel::Kernel[FilterKernel::Radius][FilterKernel::Radius]
                              * variance;
        stdDeviation = sqrt(variance);
    }

    // Add contributions from the neighborhood.
    [unroll]
    for (UINT r = 0; r < FilterKernel::Width; r++)
    [unroll]
    for (UINT c = 0; c < FilterKernel::Width; c++)
        if (r != FilterKernel::Radius || c != FilterKernel::Radius)
             AddFilterContribution(weightedValueSum, weightedVarianceSum, weightSum, value, stdDeviation, depth, normal, obliqueness, r, c, DTid);

#if WORKAROUND_ATROUS_VARYING_OUTPUTS
    float outputValue = (cb.outputFilterWeigthSum) ? weightSum : weightedValueSum / weightSum;
    g_outFilteredValues[DTid] = outputValue;
#else
    // ToDo why the resource doesnt get picked up in PIX if its written to under condition?
    if (cb.outputFilterWeigthSum)
    {
        g_outFilterWeightSum[DTid] = weightSum;
    }

    // ToDo separate output filtered value and weight sum into two shaders?
    if (cb.outputFilteredValue)
    {
        g_outFilteredValues[DTid] = weightedValueSum / weightSum;
    }
#endif
    if (cb.outputFilteredVariance)
    {
        g_outFilteredVariance[DTid] = weightedVarianceSum / (weightSum * weightSum);
    }

}