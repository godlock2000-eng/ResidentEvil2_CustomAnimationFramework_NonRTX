"""
CAF Blender Animation Exporter
Exports armature animation data as JSON for the RE Engine Custom Animation Framework.

Install: Blender > Edit > Preferences > Add-ons > Install > select this file
Usage: Select armature, open sidebar (N), CAF tab, configure, click Export

Output format: JSON with per-frame, per-bone local transforms.
Coordinate system: Raw Blender values (Z-up, right-handed).
Axis conversion to RE Engine (Y-up) is handled by the Lua player at runtime,
so the user can tweak settings without re-exporting.

Each bone transform is [qx, qy, qz, qw, px, py, pz] in Blender's local space.
Quaternion is in XYZW order (not Blender's internal WXYZ).
"""

bl_info = {
    "name": "CAF Animation Exporter",
    "author": "CAF Team",
    "version": (1, 0, 0),
    "blender": (3, 0, 0),
    "location": "View3D > Sidebar > CAF",
    "description": "Export armature animations as JSON for RE Engine Custom Animation Framework",
    "category": "Import-Export",
}

import bpy
import json
import os
from mathutils import Matrix, Quaternion, Vector
from bpy.props import StringProperty, IntProperty, BoolProperty, EnumProperty
from bpy.types import Operator, Panel, PropertyGroup


class CAF_ExportSettings(PropertyGroup):
    output_path: StringProperty(
        name="Output Path",
        description="Path for the exported JSON file",
        default="//animation_export.json",
        subtype='FILE_PATH',
    )
    frame_start: IntProperty(
        name="Start Frame",
        description="First frame to export (0 = scene start)",
        default=0,
        min=0,
    )
    frame_end: IntProperty(
        name="End Frame",
        description="Last frame to export (0 = scene end)",
        default=0,
        min=0,
    )
    fps_override: IntProperty(
        name="FPS Override",
        description="Override FPS in export metadata (0 = use scene FPS)",
        default=0,
        min=0,
        max=120,
    )
    use_scene_range: BoolProperty(
        name="Use Scene Range",
        description="Use the scene's start/end frame range",
        default=True,
    )
    export_position: BoolProperty(
        name="Export Positions",
        description="Include bone positions (not just rotations)",
        default=True,
    )
    only_deform_bones: BoolProperty(
        name="Deform Bones Only",
        description="Only export bones marked as deform bones",
        default=False,
    )
    bone_prefix_strip: StringProperty(
        name="Strip Prefix",
        description="Remove this prefix from bone names (e.g., 'Armature_')",
        default="",
    )


class CAF_OT_ExportAnimation(Operator):
    bl_idname = "caf.export_animation"
    bl_label = "Export Animation"
    bl_description = "Export the active armature's animation as CAF JSON"

    def execute(self, context):
        settings = context.scene.caf_export_settings
        armature = context.active_object

        if not armature or armature.type != 'ARMATURE':
            self.report({'ERROR'}, "Select an armature first")
            return {'CANCELLED'}

        if not armature.animation_data or not armature.animation_data.action:
            self.report({'ERROR'}, "Armature has no active action")
            return {'CANCELLED'}

        result = export_animation(context, armature, settings)
        if result:
            self.report({'INFO'}, result)
            return {'FINISHED'}
        else:
            self.report({'ERROR'}, "Export failed")
            return {'CANCELLED'}


class CAF_OT_SetRangeFromAction(Operator):
    bl_idname = "caf.set_range_from_action"
    bl_label = "Range from Action"
    bl_description = "Set frame range from the active action's keyframe range"

    def execute(self, context):
        settings = context.scene.caf_export_settings
        armature = context.active_object
        if armature and armature.animation_data and armature.animation_data.action:
            action = armature.animation_data.action
            start, end = action.frame_range
            settings.frame_start = int(start)
            settings.frame_end = int(end)
            settings.use_scene_range = False
            self.report({'INFO'}, f"Range set to {int(start)}-{int(end)}")
        return {'FINISHED'}


class CAF_PT_ExportPanel(Panel):
    bl_label = "CAF Animation Exporter"
    bl_idname = "CAF_PT_export_panel"
    bl_space_type = 'VIEW_3D'
    bl_region_type = 'UI'
    bl_category = 'CAF'

    def draw(self, context):
        layout = self.layout
        settings = context.scene.caf_export_settings
        armature = context.active_object

        # Status
        box = layout.box()
        if armature and armature.type == 'ARMATURE':
            box.label(text=f"Armature: {armature.name}", icon='ARMATURE_DATA')
            bone_count = len(armature.data.bones)
            box.label(text=f"Bones: {bone_count}")
            if armature.animation_data and armature.animation_data.action:
                action = armature.animation_data.action
                start, end = action.frame_range
                box.label(text=f"Action: {action.name} ({int(start)}-{int(end)})")
            else:
                box.label(text="No active action!", icon='ERROR')
        else:
            box.label(text="Select an armature", icon='ERROR')

        layout.separator()

        # Frame range
        layout.prop(settings, "use_scene_range")
        if not settings.use_scene_range:
            row = layout.row(align=True)
            row.prop(settings, "frame_start")
            row.prop(settings, "frame_end")
            layout.operator("caf.set_range_from_action", icon='ACTION')

        # Settings
        layout.prop(settings, "fps_override")
        layout.prop(settings, "export_position")
        layout.prop(settings, "only_deform_bones")
        layout.prop(settings, "bone_prefix_strip")

        layout.separator()

        # Output
        layout.prop(settings, "output_path")

        # Export button
        layout.separator()
        row = layout.row()
        row.scale_y = 2.0
        row.operator("caf.export_animation", icon='EXPORT')


def get_bone_local_transform(pose_bone):
    """
    Get a bone's local transform relative to its parent (or armature for root bones).
    Returns (quaternion, position) in Blender's coordinate space.
    """
    if pose_bone.parent:
        # Local relative to parent
        parent_mat_inv = pose_bone.parent.matrix.inverted_safe()
        local_mat = parent_mat_inv @ pose_bone.matrix
    else:
        # Root bone: relative to armature origin
        local_mat = pose_bone.matrix.copy()

    loc, rot, scale = local_mat.decompose()
    return rot, loc


def export_animation(context, armature, settings):
    """Main export function. Returns status string or None on failure."""

    scene = context.scene
    depsgraph = context.evaluated_depsgraph_get()

    # Determine frame range
    if settings.use_scene_range:
        frame_start = scene.frame_start
        frame_end = scene.frame_end
    else:
        frame_start = settings.frame_start
        frame_end = settings.frame_end
        if frame_end <= frame_start:
            if armature.animation_data and armature.animation_data.action:
                s, e = armature.animation_data.action.frame_range
                frame_end = int(e)
            else:
                frame_end = frame_start + 60

    frame_count = frame_end - frame_start + 1
    fps = settings.fps_override if settings.fps_override > 0 else scene.render.fps

    # Collect bones to export
    bones_to_export = []
    prefix = settings.bone_prefix_strip

    for bone in armature.data.bones:
        if settings.only_deform_bones and not bone.use_deform:
            continue
        export_name = bone.name
        if prefix and export_name.startswith(prefix):
            export_name = export_name[len(prefix):]
        bones_to_export.append({
            "blender_name": bone.name,
            "export_name": export_name,
        })

    if not bones_to_export:
        return None

    bone_names = [b["export_name"] for b in bones_to_export]

    # Sample animation frame by frame
    frames_data = []
    original_frame = scene.frame_current

    for frame_idx in range(frame_count):
        frame = frame_start + frame_idx
        scene.frame_set(frame)
        depsgraph.update()

        frame_bones = []
        for bone_info in bones_to_export:
            pose_bone = armature.pose.bones.get(bone_info["blender_name"])
            if not pose_bone:
                # Bone not found in pose — write identity
                frame_bones.append([0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0])
                continue

            rot, loc = get_bone_local_transform(pose_bone)

            # Export as [qx, qy, qz, qw, px, py, pz]
            # (XYZW order to match RE Engine convention)
            entry = [
                round(rot.x, 6),
                round(rot.y, 6),
                round(rot.z, 6),
                round(rot.w, 6),
                round(loc.x, 6) if settings.export_position else 0.0,
                round(loc.y, 6) if settings.export_position else 0.0,
                round(loc.z, 6) if settings.export_position else 0.0,
            ]
            frame_bones.append(entry)

        frames_data.append(frame_bones)

    # Restore original frame
    scene.frame_set(original_frame)

    # Build JSON
    action_name = ""
    if armature.animation_data and armature.animation_data.action:
        action_name = armature.animation_data.action.name

    output = {
        "format": "CAF_AnimData",
        "version": 1,
        "source_app": "Blender",
        "source_version": bpy.app.version_string,
        "source_coords": "z_up_rh",
        "action_name": action_name,
        "armature_name": armature.name,
        "fps": fps,
        "frame_count": frame_count,
        "frame_start": frame_start,
        "frame_end": frame_end,
        "bone_count": len(bone_names),
        "bones": bone_names,
        "has_positions": settings.export_position,
        "data": frames_data,
    }

    # Write file
    output_path = bpy.path.abspath(settings.output_path)
    os.makedirs(os.path.dirname(output_path), exist_ok=True)

    with open(output_path, 'w') as f:
        json.dump(output, f, separators=(',', ':'))

    file_size = os.path.getsize(output_path)
    size_str = f"{file_size / 1024:.1f} KB" if file_size < 1048576 else f"{file_size / 1048576:.1f} MB"

    return (f"Exported {frame_count} frames, {len(bone_names)} bones to "
            f"{output_path} ({size_str})")


# Registration
classes = (
    CAF_ExportSettings,
    CAF_OT_ExportAnimation,
    CAF_OT_SetRangeFromAction,
    CAF_PT_ExportPanel,
)


def register():
    for cls in classes:
        bpy.utils.register_class(cls)
    bpy.types.Scene.caf_export_settings = bpy.props.PointerProperty(type=CAF_ExportSettings)


def unregister():
    del bpy.types.Scene.caf_export_settings
    for cls in reversed(classes):
        bpy.utils.unregister_class(cls)


if __name__ == "__main__":
    register()
