#version 450

layout(location = 0) in vec3 pos;

layout(push_constant) uniform PushConsts {
	mat4 matrix;
} push_consts;

void main() {
    gl_Position = push_consts.matrix * vec4(pos, 1.0);
}
