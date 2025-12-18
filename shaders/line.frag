#version 450

layout(binding = 0) uniform Uniforms {
	vec4 u_color;
};

layout(location = 0) out vec4 out_color;

void main() {
	out_color = u_color;
}
