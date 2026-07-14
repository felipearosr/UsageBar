//! Renders the tray gauge icon: a ring that fills clockwise with used percent,
//! colored by severity, following the visual language of the macOS bar icon
//! (Sources/CodexBar/IconRenderer.swift) without porting its code.

use tiny_skia::{LineCap, Paint, Path, PathBuilder, Pixmap, Stroke, Transform};

pub const SIZE: u32 = 32;

/// Raw RGBA gauge pixels (SIZE×SIZE), separated from the tauri Image wrapper
/// so tests can inspect output without a running app.
pub fn render_rgba(used_percent: Option<f64>, error: bool) -> Vec<u8> {
    let mut pixmap = Pixmap::new(SIZE, SIZE).expect("pixmap");
    let center = SIZE as f32 / 2.0;
    let radius = center - 3.5;
    let stroke = Stroke {
        width: 4.0,
        line_cap: LineCap::Round,
        ..Stroke::default()
    };

    let mut track = Paint::default();
    track.anti_alias = true;
    track.set_color_rgba8(140, 140, 140, 110);
    if let Some(path) = ring_path(center, center, radius, 1.0) {
        pixmap.stroke_path(&path, &track, &stroke, Transform::identity(), None);
    }

    match used_percent {
        Some(p) => {
            let frac = (p / 100.0).clamp(0.0, 1.0) as f32;
            if frac > 0.005 {
                let (r, g, b) = severity_color(p);
                let mut fill = Paint::default();
                fill.anti_alias = true;
                fill.set_color_rgba8(r, g, b, 255);
                if let Some(path) = ring_path(center, center, radius, frac) {
                    pixmap.stroke_path(&path, &fill, &stroke, Transform::identity(), None);
                }
            }
        }
        None => {
            // Unknown usage: neutral center dot.
            let mut dot = Paint::default();
            dot.anti_alias = true;
            dot.set_color_rgba8(140, 140, 140, 200);
            if let Some(path) = disc_path(center, center, 3.0) {
                pixmap.fill_path(
                    &path,
                    &dot,
                    tiny_skia::FillRule::Winding,
                    Transform::identity(),
                    None,
                );
            }
        }
    }

    if error {
        let mut warn = Paint::default();
        warn.anti_alias = true;
        warn.set_color_rgba8(224, 79, 79, 255);
        if let Some(path) = disc_path(SIZE as f32 - 5.0, SIZE as f32 - 5.0, 4.0) {
            pixmap.fill_path(
                &path,
                &warn,
                tiny_skia::FillRule::Winding,
                Transform::identity(),
                None,
            );
        }
    }

    pixmap.take()
}

pub fn render(used_percent: Option<f64>, error: bool) -> tauri::image::Image<'static> {
    tauri::image::Image::new_owned(render_rgba(used_percent, error), SIZE, SIZE)
}

/// Green while comfortable, amber when high, red when nearly exhausted.
fn severity_color(used_percent: f64) -> (u8, u8, u8) {
    if used_percent < 50.0 {
        (46, 184, 114)
    } else if used_percent < 80.0 {
        (232, 160, 46)
    } else {
        (224, 79, 79)
    }
}

/// Arc from 12 o'clock, clockwise, covering `frac` of the circle, as a
/// polyline (tiny-skia has no arc primitive; 64 segments is smooth at 32px).
fn ring_path(cx: f32, cy: f32, r: f32, frac: f32) -> Option<Path> {
    let steps = ((64.0 * frac).ceil() as usize).max(2);
    let mut pb = PathBuilder::new();
    for i in 0..=steps {
        let t = -std::f32::consts::FRAC_PI_2
            + (i as f32 / steps as f32) * frac * std::f32::consts::TAU;
        let (x, y) = (cx + r * t.cos(), cy + r * t.sin());
        if i == 0 {
            pb.move_to(x, y);
        } else {
            pb.line_to(x, y);
        }
    }
    pb.finish()
}

fn disc_path(cx: f32, cy: f32, r: f32) -> Option<Path> {
    let mut pb = PathBuilder::new();
    pb.push_circle(cx, cy, r);
    pb.finish()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn opaque_pixels(rgba: &[u8]) -> usize {
        rgba.chunks_exact(4).filter(|px| px[3] > 0).count()
    }

    #[test]
    fn renders_expected_buffer_size() {
        let rgba = render_rgba(Some(50.0), false);
        assert_eq!(rgba.len(), (SIZE * SIZE * 4) as usize);
        assert!(opaque_pixels(&rgba) > 0);
    }

    #[test]
    fn higher_usage_paints_more_colored_pixels() {
        let low = render_rgba(Some(10.0), false);
        let high = render_rgba(Some(90.0), false);
        assert_ne!(low, high);
        let colored = |rgba: &[u8]| {
            rgba.chunks_exact(4)
                .filter(|px| px[3] == 255 && (px[0] != px[1] || px[1] != px[2]))
                .count()
        };
        assert!(colored(&high) > colored(&low));
    }

    #[test]
    fn unknown_usage_and_error_states_render() {
        let unknown = render_rgba(None, false);
        let unknown_err = render_rgba(None, true);
        assert_ne!(unknown, unknown_err);
        assert!(opaque_pixels(&unknown) > 0);
    }
}
