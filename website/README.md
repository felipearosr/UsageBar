# UsageBar website

The marketing site for UsageBar and Machine Sync, meant for `usagebar.dev`. It is plain static files with no build
step: `index.html`, `styles.css`, `script.js` and `assets/`.

## Preview

```sh
python3 -m http.server --directory website 8000   # then open http://localhost:8000
```

Opening `website/index.html` straight from disk works too.

## Deploy

Serve this directory as the site root on any static host. On Vercel, set the project's Root Directory to `website`
and leave the build command empty.

## Screenshots

The screenshots in `assets/screenshots/` come from the real extension, running in a headless GNOME Shell of its own
against `tools/demo-codexbar`, a stand-in CLI with made-up data. No account, config or home directory of yours is
read. Retake them after a UI change:

```sh
website/tools/capture-screenshots.sh
```

It needs `gnome-shell`, `python3` and ImageMagick, takes about two minutes, and writes a dark and a light set. If a
screenshot's size changes, update the `width` and `height` on its `<img>` in `index.html`.

- `tools/demo-codexbar`: the demo data (providers, quota, spend, Machines). Edit it to change what the screenshots show.
- `tools/shots-driver/`: a GNOME Shell extension, loaded only by the capture script, that opens each surface and
  saves a screenshot of it.
- `tools/crop-screenshots.py`: crops the full-screen captures to the popover, dashboard or window.

`assets/og.png` is the link-preview image. Its source is `tools/og.html`: open it in a 1200×630 browser window and
save a screenshot over `assets/og.png`.

## Provider strip

The scrolling provider tiles are generated. `tools/gen-providers.py` copies each provider's icon from
`Sources/CodexBar/Resources` into `assets/providers/` and rewrites the marked blocks in `index.html` and `styles.css`.
To change which providers show or how one is colored, edit `BRANDS`, `ROW1` and `ROW2` at the top of the script and
run it again:

```sh
python3 website/tools/gen-providers.py
```

Claude, Codex, Mistral, Vertex AI and Bedrock use the repo's full-color brand artwork. The other colors are set by
hand in the script.

## Facts to keep current

- The Hosted Sync price and plan limits in the Machine Sync section match what `sync.usagebar.dev` charges.
- The supported GNOME and distro versions in the Install section match `linux/INSTALL.md`.
