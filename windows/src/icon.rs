// SPDX-License-Identifier: GPL-3.0-or-later — Copyright (C) 2026 jeremdevgit — voir LICENSE
// Icône de la Boîte à outils dessinée par calcul (aucune image dans le dépôt) :
// une caisse à outils blanche sur un carré en dégradé bleu → turquoise.
// Partagé avec build.rs.

#[allow(dead_code)]
pub fn render_icon(size: u32) -> Vec<u8> {
    let s = size as f32;
    let mut out = vec![0u8; (size * size * 4) as usize];
    const SS: u32 = 4; // suréchantillonnage pour des bords lisses
    for py in 0..size {
        for px in 0..size {
            let mut acc = [0f32; 4];
            for sy in 0..SS {
                for sx in 0..SS {
                    let x = (px as f32 + (sx as f32 + 0.5) / SS as f32) / s;
                    let y = (py as f32 + (sy as f32 + 0.5) / SS as f32) / s;
                    let c = sample(x, y);
                    let a = c[3];
                    for k in 0..3 {
                        acc[k] += c[k] * a;
                    }
                    acc[3] += a;
                }
            }
            let n = (SS * SS) as f32;
            let a = acc[3] / n;
            let i = ((py * size + px) * 4) as usize;
            if a > 0.0 {
                for k in 0..3 {
                    out[i + k] = ((acc[k] / acc[3]).clamp(0.0, 1.0) * 255.0) as u8;
                }
            }
            out[i + 3] = (a.clamp(0.0, 1.0) * 255.0) as u8;
        }
    }
    out
}

fn mix(a: [f32; 3], b: [f32; 3], t: f32) -> [f32; 3] {
    [a[0] + (b[0] - a[0]) * t, a[1] + (b[1] - a[1]) * t, a[2] + (b[2] - a[2]) * t]
}

/// Distance signée à un rectangle arrondi (négative à l'intérieur).
fn rrect(x: f32, y: f32, x0: f32, y0: f32, x1: f32, y1: f32, r: f32) -> f32 {
    let (cx, cy) = ((x0 + x1) / 2.0, (y0 + y1) / 2.0);
    let (hx, hy) = ((x1 - x0) / 2.0 - r, (y1 - y0) / 2.0 - r);
    let (dx, dy) = ((x - cx).abs() - hx, (y - cy).abs() - hy);
    let out = (dx.max(0.0).powi(2) + dy.max(0.0).powi(2)).sqrt();
    out + dx.max(dy).min(0.0) - r
}

/// Couleur RGBA (0..1) au point (x, y) de l'icône (coordonnées 0..1).
fn sample(x: f32, y: f32) -> [f32; 4] {
    if rrect(x, y, 0.0, 0.0, 1.0, 1.0, 0.22) > 0.0 {
        return [0.0; 4];
    }
    // fond : dégradé bleu → turquoise, reflet en haut
    let t = (x * 0.4 + y * 0.6).clamp(0.0, 1.0);
    let mut col = mix([0.23, 0.42, 0.98], [0.10, 0.80, 0.74], t);
    if y < 0.4 {
        col = mix(col, [1.0, 1.0, 1.0], (0.4 - y) * 0.25);
    }
    // poignée : contour arrondi au-dessus de la caisse
    let handle = rrect(x, y, 0.36, 0.22, 0.64, 0.44, 0.06);
    let in_handle = handle < 0.0 && handle > -0.055;
    // caisse et couvercle
    let body = rrect(x, y, 0.17, 0.38, 0.83, 0.80, 0.06) < 0.0;
    let lid_line = body && (y - 0.53).abs() < 0.022;
    let latch = rrect(x, y, 0.44, 0.48, 0.56, 0.60, 0.025) < 0.0;
    if latch {
        let c = mix([0.23, 0.42, 0.98], [0.10, 0.80, 0.74], t);
        return [c[0], c[1], c[2], 1.0];
    }
    if lid_line {
        return [0.80, 0.86, 0.95, 1.0];
    }
    if body || (in_handle && y < 0.40) {
        return [1.0, 1.0, 1.0, 1.0];
    }
    [col[0], col[1], col[2], 1.0]
}

/// Fichier .ico multi-tailles (BMP 32 bits).
#[allow(dead_code)]
pub fn ico_bytes(sizes: &[u32]) -> Vec<u8> {
    let mut images = Vec::new();
    for &sz in sizes {
        let rgba = render_icon(sz);
        let mut bmp = Vec::new();
        bmp.extend_from_slice(&40u32.to_le_bytes());
        bmp.extend_from_slice(&(sz as i32).to_le_bytes());
        bmp.extend_from_slice(&((sz * 2) as i32).to_le_bytes());
        bmp.extend_from_slice(&1u16.to_le_bytes());
        bmp.extend_from_slice(&32u16.to_le_bytes());
        bmp.extend_from_slice(&[0u8; 24]);
        for y in (0..sz).rev() {
            for x in 0..sz {
                let i = ((y * sz + x) * 4) as usize;
                bmp.extend_from_slice(&[rgba[i + 2], rgba[i + 1], rgba[i], rgba[i + 3]]);
            }
        }
        let mask_row = sz.div_ceil(32) * 4;
        bmp.extend(std::iter::repeat(0u8).take((mask_row * sz) as usize));
        images.push((sz, bmp));
    }
    let mut out = Vec::new();
    out.extend_from_slice(&[0, 0, 1, 0]);
    out.extend_from_slice(&(images.len() as u16).to_le_bytes());
    let mut offset = 6 + 16 * images.len() as u32;
    for (sz, data) in &images {
        let d = if *sz >= 256 { 0 } else { *sz as u8 };
        out.extend_from_slice(&[d, d, 0, 0]);
        out.extend_from_slice(&1u16.to_le_bytes());
        out.extend_from_slice(&32u16.to_le_bytes());
        out.extend_from_slice(&(data.len() as u32).to_le_bytes());
        out.extend_from_slice(&offset.to_le_bytes());
        offset += data.len() as u32;
    }
    for (_, data) in images {
        out.extend_from_slice(&data);
    }
    out
}
