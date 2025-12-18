#version 450

layout(location = 0) in vec2 tex_coord;

layout(binding = 0) uniform Uniforms {
	vec4 u_color;
};

layout(binding = 1) uniform sampler2D u_texture;

layout(location = 0) out vec4 out_color;

void main() {
	out_color = texture(u_texture, tex_coord);
}
