// The WebGPU `cubelove` kernel is not vendored, but BackdropEngine + types.ts
// retain a (dead) `webgpu` substrate branch. Stub the one referenced type so the
// engine compiles without pulling in @webgpu/types.
declare type GPUCanvasContext = unknown;
