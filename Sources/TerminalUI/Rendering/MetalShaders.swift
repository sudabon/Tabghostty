/// Metal のシェーダー（phase5 design D1）。
///
/// Command Line Tools には Metal のコンパイラ（`metal` / `metallib`）が無く、SwiftPM のリソースとして `.metal` を
/// 処理できない。そのため、ソースを文字列として持ち、起動時に `MTLDevice.makeLibrary(source:options:)` でコンパイルする。
///
/// 座標はビューの左上を原点とする device pixel。色は sRGB の値のまま（Core Graphics と同じく、ガンマのかかった値で合成する）。
/// フラグメントシェーダーは premultiplied alpha の色を返し、合成は `one, oneMinusSourceAlpha` で行う。
///
/// インスタンスの構造体は、Swift 側の `RectInstance` / `GlyphInstance` / `ImageInstance`（`MetalRenderer.swift`）と
/// 同じ並び（すべて float4）にする。
enum MetalShaders {
    static let source = """
    #include <metal_stdlib>
    using namespace metal;

    struct Uniforms {
        float2 viewportSize;
    };

    // 矩形（背景、選択、検索の強調、下線、カーソル、IME の下地）。
    struct RectInstance {
        float4 rect;    // x, y, w, h（px）
        float4 color;   // sRGB の r, g, b, a（straight alpha）
        float4 params;  // x: 0 = 塗りつぶし, 1 = 波線。y: 線の太さ, z: 振幅, w: 周期（px）
    };

    // グリフ（アトラスから取り、前景色で着色する）。
    struct GlyphInstance {
        float4 rect;    // x, y, w, h（px）
        float4 uv;      // アトラスの x, y, w, h（px）
        float4 color;   // モノクロは前景色。カラーは a だけを使う（faint）
        float4 params;  // x: 0 = モノクロ（R8）, 1 = カラー（BGRA8, premultiplied）
    };

    // 画像（Kitty Graphics）。
    struct ImageInstance {
        float4 rect;    // x, y, w, h（px）
        float4 uv;      // テクスチャの x, y, w, h（0〜1）
    };

    constant float2 corners[4] = { float2(0, 0), float2(1, 0), float2(0, 1), float2(1, 1) };

    static float4 toClip(float2 px, float2 viewport) {
        return float4(px.x / viewport.x * 2.0 - 1.0, 1.0 - px.y / viewport.y * 2.0, 0.0, 1.0);
    }

    struct RectOut {
        float4 position [[position]];
        float4 color;
        float4 params;
        float2 local;
        float2 size;
    };

    vertex RectOut rect_vertex(uint vid [[vertex_id]], uint iid [[instance_id]],
                               constant Uniforms& uniforms [[buffer(0)]],
                               const device RectInstance* instances [[buffer(1)]]) {
        RectInstance instance = instances[iid];
        float2 corner = corners[vid];
        RectOut out;
        out.position = toClip(instance.rect.xy + corner * instance.rect.zw, uniforms.viewportSize);
        out.color = instance.color;
        out.params = instance.params;
        out.local = corner * instance.rect.zw;
        out.size = instance.rect.zw;
        return out;
    }

    fragment float4 rect_fragment(RectOut in [[stage_in]]) {
        float alpha = in.color.a;
        if (in.params.x > 0.5) {
            // 波線: 帯の中央を通る正弦波。Core Text の 2 次ベジェ（半周期ごとに制御点を ±振幅）と同じ形にする。
            float center = in.size.y * 0.5;
            float wave = center - in.params.z * sin(in.local.x / in.params.w * 2.0 * M_PI_F);
            float distance = abs(in.local.y - wave);
            alpha *= clamp(in.params.y * 0.5 + 0.5 - distance, 0.0, 1.0);
        }
        return float4(in.color.rgb * alpha, alpha);
    }

    struct GlyphOut {
        float4 position [[position]];
        float2 uv;
        float4 color;
        float kind;
    };

    vertex GlyphOut glyph_vertex(uint vid [[vertex_id]], uint iid [[instance_id]],
                                 constant Uniforms& uniforms [[buffer(0)]],
                                 const device GlyphInstance* instances [[buffer(1)]]) {
        GlyphInstance instance = instances[iid];
        float2 corner = corners[vid];
        GlyphOut out;
        out.position = toClip(instance.rect.xy + corner * instance.rect.zw, uniforms.viewportSize);
        out.uv = instance.uv.xy + corner * instance.uv.zw;
        out.color = instance.color;
        out.kind = instance.params.x;
        return out;
    }

    fragment float4 glyph_fragment(GlyphOut in [[stage_in]],
                                   texture2d<float> grayscale [[texture(0)]],
                                   texture2d<float> color [[texture(1)]]) {
        // グリフは device pixel の格子に合わせて置くので、補間せずに読む。
        constexpr sampler atlas(coord::pixel, filter::nearest, address::clamp_to_edge);
        if (in.kind > 0.5) {
            return color.sample(atlas, in.uv) * in.color.a;
        }
        float alpha = grayscale.sample(atlas, in.uv).r * in.color.a;
        return float4(in.color.rgb * alpha, alpha);
    }

    struct ImageOut {
        float4 position [[position]];
        float2 uv;
    };

    vertex ImageOut image_vertex(uint vid [[vertex_id]], uint iid [[instance_id]],
                                 constant Uniforms& uniforms [[buffer(0)]],
                                 const device ImageInstance* instances [[buffer(1)]]) {
        ImageInstance instance = instances[iid];
        float2 corner = corners[vid];
        ImageOut out;
        out.position = toClip(instance.rect.xy + corner * instance.rect.zw, uniforms.viewportSize);
        out.uv = instance.uv.xy + corner * instance.uv.zw;
        return out;
    }

    fragment float4 image_fragment(ImageOut in [[stage_in]], texture2d<float> image [[texture(0)]]) {
        constexpr sampler smooth(coord::normalized, filter::linear, address::clamp_to_edge);
        // テクスチャは straight alpha の RGBA。
        float4 c = image.sample(smooth, in.uv);
        return float4(c.rgb * c.a, c.a);
    }
    """
}
