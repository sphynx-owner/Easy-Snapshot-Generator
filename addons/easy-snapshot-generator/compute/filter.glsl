#[compute]
#version 450

#define EPSILON 0.02

layout(set = 0, binding = 0) uniform sampler2D normal_snapshot;
layout(set = 0, binding = 1) uniform sampler2D missing_snapshot;
layout(rgba16f, set = 0, binding = 2) uniform writeonly image2D output_color_image;

layout(push_constant, std430) uniform Params 
{	
	int h_frames;
	int v_frames;
	int current_frame;
	int nan1;
} params;


layout(local_size_x = 16, local_size_y = 16, local_size_z = 1) in;

void main() 
{    
	ivec2 render_size = ivec2(textureSize(normal_snapshot, 0));
	ivec2 uvi = ivec2(gl_GlobalInvocationID.xy);
	if ((uvi.x >= render_size.x) || (uvi.y >= render_size.y)) 
	{
		return;
	}
	// must be on pixel center for whole values (tested)
	vec2 uvn = vec2(uvi) / render_size;
	
	ivec2 atlas_offset = ivec2(params.current_frame % params.h_frames, params.current_frame / params.h_frames);

	ivec2 uvi_offset = atlas_offset * render_size;

    vec4 normal_sample = texelFetch(normal_snapshot, uvi, 0);
	vec4 missing_sample = texelFetch(missing_snapshot, render_size - uvi - ivec2(1), 0);

	vec4 difference = normal_sample - missing_sample;

    if(abs(difference.x) < EPSILON && abs(difference.y) < EPSILON && abs(difference.z) < EPSILON && abs(difference.w) < EPSILON)
    {
        imageStore(output_color_image, uvi + uvi_offset, vec4(0));
    }
	else
	{
    	imageStore(output_color_image, uvi + uvi_offset, missing_sample);
	}
}