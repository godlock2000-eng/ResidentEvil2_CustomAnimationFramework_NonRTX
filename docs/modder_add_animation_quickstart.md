# CAF Modder Quickstart: Add One Animation

Use these steps to add a simple custom animation mod package to RE2.

## 1) Build animation binaries

- Convert JSON animation data to motlist:
  - `python tools/mot_writer.py convert input.json output.motlist.85 --ref tools/test_output/dodge_front.motlist.85 --uncompressed`
- Build motbank wrapper:
  - `python tools/motbank_writer.py CAF_custom/my_anim.motlist output.motbank.1 --bank-id 950 --layer-mask 0xFFFFFFFF`

Notes:
- `bank_id` in motbank and manifest must match.
- `--layer-mask 0xFFFFFFFF` is recommended for Layer 1 overlays.

## 2) Copy files to framework/game layout

- `framework/natives/x64/CAF_custom/my_anim.motlist.85`
- `framework/natives/x64/CAF_custom/my_anim.motbank.1`

## 3) Create manifest

Create `framework/reframework/data/CAF_mods/my_mod/manifest.json`:

```json
{
    "format_version": 1,
    "mod_name": "My Animation",
    "mod_id": "my_mod",
    "author": "YourName",
    "version": "1.0.0",
    "description": "Simple custom animation mod.",
    "game": "re2",
    "animations": [
        {
            "id": "my_anim",
            "type": "single",
            "bank_path": "CAF_custom/my_anim.motbank",
            "bank_id": 950,
            "motion_id": 0,
            "end_frame": 59,
            "speed": 1.0,
            "blend_frames": 0,
            "fsm_mode": "overlay"
        }
    ],
    "event_bindings": [
        {
            "animation_id": "my_anim",
            "event": "key_pressed",
            "conditions": { "keycode": 71 }
        }
    ]
}
```

## 4) Register mod

Add your mod id to `framework/reframework/data/CAF_mods/index.json`:

```json
{
    "mods": ["re3_dodge", "headnod", "my_mod"]
}
```

## 5) Test

- Deploy `framework/reframework` and `framework/natives` to your game folder.
- Start RE2 and open REFramework menu.
- Verify your mod appears under `CAF Mod API`.
- Press your trigger key (example: `G` / keycode `71`).

## Included references

- `examples/re3_dodge/manifest.json`
- `examples/headnod/manifest.json`
- `framework/reframework/data/CAF_mods/headnod/manifest.json`

