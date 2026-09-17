# AA_GLB_EXPORT — Agency Agents sanctioned Blender glTF export preset (Blender 4.5).
# Spec: docs/art_pipeline/AA-ARTPIPE-1_blender_gltf_export_and_linter_v1.md (section 7)
#
# Install (macOS):
#   cp AA_GLB_EXPORT.py "$HOME/Library/Application Support/Blender/4.5/scripts/presets/operator/io_scene_gltf2/"
# Linux:  ~/.config/blender/4.5/scripts/presets/operator/io_scene_gltf2/
# Windows: %APPDATA%\Blender Foundation\Blender\4.5\scripts\presets\operator\io_scene_gltf2\
#
# Select in File > Export > glTF 2.0 > Operator Presets dropdown: "AA_GLB_EXPORT".
# File is authoritative over the summary table in the spec.
import bpy

op = bpy.context.active_operator

# --- container / axes -------------------------------------------------------
op.export_format = 'GLB'
op.export_yup = True

# --- geometry ---------------------------------------------------------------
op.export_apply = True          # apply modifiers at export
op.export_texcoords = True
op.export_normals = True
op.export_tangents = True       # engine normal mapping without recompute
op.export_colors = 'MATERIAL'
op.export_extras = False

# --- materials --------------------------------------------------------------
op.export_materials = 'EXPORT'
op.export_image_format = 'AUTO'
op.export_jpeg_quality = 75
op.export_image_add_webp = False
op.export_texture_dir = ''
op.export_keep_originals = False

# --- animation / skinning ---------------------------------------------------
op.export_animations = True
op.export_current_frame = False
op.export_skins = True
op.export_all_influences = False
op.export_deformation_bones_only = True
op.export_rest_position_armature = True
op.export_leaf_bones = False
op.export_force_sampling = True
op.export_optimize_animation = True
op.export_optimize_animation_size = True
op.export_optimize_rest_position = True
op.export_animation_mode = 'ACTIONS'
op.export_def_bones = False

# --- shape keys -------------------------------------------------------------
op.export_shapekeys = True
op.export_morph = True
op.export_morph_normal = True
op.export_morph_tangent = False

# --- compression (engines compress; draco off, spec section 7) --------------
op.export_draco_mesh_compression_enable = False
op.export_draco_animation_compression_enable = False

# --- instancing -------------------------------------------------------------
op.export_gpu_instances = False
