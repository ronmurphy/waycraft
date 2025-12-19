#version 450

layout(location = 0) in vec3 pos;
layout(location = 1) in vec2 tex_coord;

layout(location = 0) out vec2 out_tex_coord;
layout(location = 1) out vec4 out_color;

layout(push_constant) uniform PushConsts {
	mat4 matrix;
    vec4 color;
} push_consts;

void main() {
    gl_Position = push_consts.matrix * vec4(pos, 1.0);

    out_tex_coord = tex_coord;
    out_color = push_consts.color;
}
