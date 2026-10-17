# AGA extension plan

Status: proposed, not implemented. The current release remains the four-plane
OCS/ECS Crimson demo.

1. Detect AGA and retain the current display as a fallback.
2. Specify the colour allocation, palette banks and compatibility register reset.
3. Allocate and verify all DMA buffers, including every front/back plane.
4. Implement a bounded filled-polygon renderer before adding interpolation.
5. Add independent reference images for clipping, edge rules, depth and shading.
6. Measure CPU and DMA cost on cycle-exact A1200 emulation; do not reuse OCS timing
   numbers for a wider display fetch.
7. Integrate one experimental effect at a time and verify takeover/restore on both
   OCS/ECS and AGA paths.

The Python lighting, glow, starfield and plasma helpers are algorithm experiments,
not proof of an Amiga implementation. A release needs generated tables wired into
assembly, framebuffer bounds checks and complete scene-cycle tests.
