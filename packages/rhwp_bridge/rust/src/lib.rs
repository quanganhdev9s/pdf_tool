use std::cell::RefCell;
use std::collections::HashMap;
use std::ffi::{CStr, CString};
use std::fs;
use std::os::raw::{c_char, c_double, c_uint, c_ulonglong};
use std::path::Path;
use std::sync::atomic::{AtomicU64, Ordering};

use rhwp_core::wasm_api::HwpDocument;
use serde::Serialize;

static NEXT_HANDLE: AtomicU64 = AtomicU64::new(1);

thread_local! {
    static DOCUMENTS: RefCell<HashMap<u64, HwpDocument>> = RefCell::new(HashMap::new());
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct ErrorResponse {
    ok: bool,
    error: String,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct OpenResponse {
    ok: bool,
    handle: u64,
    page_count: u32,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct PageCountResponse {
    ok: bool,
    page_count: u32,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct TextResponse {
    ok: bool,
    page_count: u32,
    text: String,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct RenderPageResponse {
    ok: bool,
    page_index: u32,
    svg: String,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct JsonResponse {
    ok: bool,
    json: String,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct EditResponse {
    ok: bool,
    replacement_count: u64,
    raw_result: serde_json::Value,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct SaveResponse {
    ok: bool,
    output_path: String,
    file_size_bytes: u64,
    validated: bool,
}

#[no_mangle]
pub extern "C" fn rhwp_bridge_version() -> *mut c_char {
    into_c_string(&format!(
        "rhwp-bridge/{} rhwp/{}",
        env!("CARGO_PKG_VERSION"),
        rhwp_core::version()
    ))
}

#[no_mangle]
pub extern "C" fn rhwp_bridge_open_path(input_path: *const c_char) -> *mut c_char {
    ffi_result(|| {
        let input_path = read_utf8(input_path, "input_path")?;
        let data = fs::read(&input_path)
            .map_err(|error| format!("Cannot read HWP file at {}: {}", input_path, error))?;
        let document = HwpDocument::from_bytes(&data)
            .map_err(|error| format!("Cannot parse HWP document: {}", error))?;
        let page_count = document.page_count();
        let handle = NEXT_HANDLE.fetch_add(1, Ordering::Relaxed);
        DOCUMENTS.with(|documents| {
            documents.borrow_mut().insert(handle, document);
        });
        Ok(OpenResponse {
            ok: true,
            handle,
            page_count,
        })
    })
}

#[no_mangle]
pub extern "C" fn rhwp_bridge_close(handle: c_ulonglong) -> *mut c_char {
    ffi_result(|| {
        DOCUMENTS.with(|documents| {
            documents.borrow_mut().remove(&(handle as u64));
        });
        Ok(serde_json::json!({ "ok": true }))
    })
}

#[no_mangle]
pub extern "C" fn rhwp_bridge_page_count(handle: c_ulonglong) -> *mut c_char {
    ffi_result(|| {
        with_document(handle as u64, |document| {
            Ok(PageCountResponse {
                ok: true,
                page_count: document.page_count(),
            })
        })
    })
}

#[no_mangle]
pub extern "C" fn rhwp_bridge_extract_text(handle: c_ulonglong) -> *mut c_char {
    ffi_result(|| {
        with_document(handle as u64, |document| {
            let page_count = document.page_count();
            let mut text = String::new();
            for page in 0..page_count {
                if page > 0 {
                    text.push_str("\n\n");
                }
                text.push_str(
                    &document
                        .extract_page_text_native(page)
                        .map_err(|error| format!("Cannot extract page {} text: {}", page, error))?,
                );
            }
            Ok(TextResponse {
                ok: true,
                page_count,
                text,
            })
        })
    })
}

#[no_mangle]
pub extern "C" fn rhwp_bridge_render_page_svg(
    handle: c_ulonglong,
    page_index: c_uint,
) -> *mut c_char {
    ffi_result(|| {
        with_document(handle as u64, |document| {
            let page_index = page_index as u32;
            let svg = document
                .render_page_svg_native(page_index)
                .map_err(|error| format!("Cannot render page {} SVG: {}", page_index, error))?;
            Ok(RenderPageResponse {
                ok: true,
                page_index,
                svg,
            })
        })
    })
}

#[no_mangle]
pub extern "C" fn rhwp_bridge_hit_test(
    handle: c_ulonglong,
    page_index: c_uint,
    x: c_double,
    y: c_double,
) -> *mut c_char {
    ffi_result(|| {
        with_document(handle as u64, |document| {
            let json = document
                .hit_test_native(page_index as u32, x as f64, y as f64)
                .map_err(|error| format!("Cannot hit-test page {}: {}", page_index, error))?;
            Ok(JsonResponse { ok: true, json })
        })
    })
}

#[no_mangle]
pub extern "C" fn rhwp_bridge_get_cursor_rect(
    handle: c_ulonglong,
    section_index: c_uint,
    paragraph_index: c_uint,
    char_offset: c_uint,
) -> *mut c_char {
    ffi_result(|| {
        with_document(handle as u64, |document| {
            let json = document
                .get_cursor_rect_native(
                    section_index as usize,
                    paragraph_index as usize,
                    char_offset as usize,
                )
                .map_err(|error| format!("Cannot get cursor rect: {}", error))?;
            Ok(JsonResponse { ok: true, json })
        })
    })
}

#[no_mangle]
pub extern "C" fn rhwp_bridge_insert_text(
    handle: c_ulonglong,
    section_index: c_uint,
    paragraph_index: c_uint,
    char_offset: c_uint,
    text: *const c_char,
) -> *mut c_char {
    ffi_result(|| {
        let text = read_utf8(text, "text")?;
        with_document(handle as u64, |document| {
            let json = document
                .insert_text_native(
                    section_index as usize,
                    paragraph_index as usize,
                    char_offset as usize,
                    &text,
                )
                .map_err(|error| format!("Cannot insert text: {}", error))?;
            Ok(JsonResponse { ok: true, json })
        })
    })
}

#[no_mangle]
pub extern "C" fn rhwp_bridge_delete_text(
    handle: c_ulonglong,
    section_index: c_uint,
    paragraph_index: c_uint,
    char_offset: c_uint,
    count: c_uint,
) -> *mut c_char {
    ffi_result(|| {
        with_document(handle as u64, |document| {
            let json = document
                .delete_text_native(
                    section_index as usize,
                    paragraph_index as usize,
                    char_offset as usize,
                    count as usize,
                )
                .map_err(|error| format!("Cannot delete text: {}", error))?;
            Ok(JsonResponse { ok: true, json })
        })
    })
}

#[no_mangle]
pub extern "C" fn rhwp_bridge_split_paragraph(
    handle: c_ulonglong,
    section_index: c_uint,
    paragraph_index: c_uint,
    char_offset: c_uint,
) -> *mut c_char {
    ffi_result(|| {
        with_document(handle as u64, |document| {
            let json = document
                .split_paragraph_native(
                    section_index as usize,
                    paragraph_index as usize,
                    char_offset as usize,
                    None,
                )
                .map_err(|error| format!("Cannot split paragraph: {}", error))?;
            Ok(JsonResponse { ok: true, json })
        })
    })
}

#[no_mangle]
pub extern "C" fn rhwp_bridge_merge_paragraph(
    handle: c_ulonglong,
    section_index: c_uint,
    paragraph_index: c_uint,
) -> *mut c_char {
    ffi_result(|| {
        with_document(handle as u64, |document| {
            let json = document
                .merge_paragraph_native(section_index as usize, paragraph_index as usize)
                .map_err(|error| format!("Cannot merge paragraph: {}", error))?;
            Ok(JsonResponse { ok: true, json })
        })
    })
}

#[no_mangle]
pub extern "C" fn rhwp_bridge_replace_text(
    handle: c_ulonglong,
    find: *const c_char,
    replacement: *const c_char,
    case_sensitive: bool,
    replace_all: bool,
) -> *mut c_char {
    ffi_result(|| {
        let find = read_utf8(find, "find")?;
        let replacement = read_utf8(replacement, "replacement")?;
        with_document(handle as u64, |document| {
            let raw = if replace_all {
                document
                    .replace_all_native(&find, &replacement, case_sensitive)
                    .map_err(|error| format!("Cannot replace text: {}", error))?
            } else {
                document
                    .replace_one_native(&find, &replacement, case_sensitive)
                    .map_err(|error| format!("Cannot replace text: {}", error))?
            };
            let raw_result = serde_json::from_str::<serde_json::Value>(&raw)
                .unwrap_or_else(|_| serde_json::json!({ "raw": raw }));
            let replacement_count = replacement_count(&raw_result);
            Ok(EditResponse {
                ok: true,
                replacement_count,
                raw_result,
            })
        })
    })
}

#[no_mangle]
pub extern "C" fn rhwp_bridge_export(
    handle: c_ulonglong,
    output_path: *const c_char,
) -> *mut c_char {
    ffi_result(|| {
        let output_path = read_utf8(output_path, "output_path")?;
        let extension = Path::new(&output_path)
            .extension()
            .and_then(|value| value.to_str())
            .unwrap_or_default()
            .to_ascii_lowercase();
        with_document(handle as u64, |document| {
            let bytes = match extension.as_str() {
                "hwpx" => document
                    .export_hwpx_native()
                    .map_err(|error| format!("Cannot export HWPX: {}", error))?,
                _ => document
                    .export_hwp_with_adapter_snapshot()
                    .map_err(|error| format!("Cannot export HWP: {}", error))?,
            };
            let validated = HwpDocument::from_bytes(&bytes).is_ok();
            fs::write(&output_path, &bytes)
                .map_err(|error| format!("Cannot write HWP file at {}: {}", output_path, error))?;
            Ok(SaveResponse {
                ok: true,
                output_path,
                file_size_bytes: bytes.len() as u64,
                validated,
            })
        })
    })
}

#[no_mangle]
pub unsafe extern "C" fn rhwp_bridge_string_free(value: *mut c_char) {
    if value.is_null() {
        return;
    }
    let _ = CString::from_raw(value);
}

fn with_document<T>(
    handle: u64,
    f: impl FnOnce(&mut HwpDocument) -> Result<T, String>,
) -> Result<T, String> {
    DOCUMENTS.with(|documents| {
        let mut documents = documents.borrow_mut();
        let document = documents
            .get_mut(&handle)
            .ok_or_else(|| format!("HWP document handle {} is not open.", handle))?;
        f(document)
    })
}

fn ffi_result<T: Serialize>(f: impl FnOnce() -> Result<T, String>) -> *mut c_char {
    match f() {
        Ok(value) => into_json(value),
        Err(error) => into_json(ErrorResponse { ok: false, error }),
    }
}

fn into_json<T: Serialize>(value: T) -> *mut c_char {
    match serde_json::to_string(&value) {
        Ok(json) => into_c_string(&json),
        Err(error) => into_c_string(&format!(
            r#"{{"ok":false,"error":"Cannot serialize bridge response: {}"}}"#,
            error
        )),
    }
}

fn into_c_string(value: &str) -> *mut c_char {
    let sanitized = value.replace('\0', "\\u0000");
    CString::new(sanitized)
        .expect("NUL bytes are sanitized before returning C strings")
        .into_raw()
}

fn read_utf8(value: *const c_char, name: &str) -> Result<String, String> {
    if value.is_null() {
        return Err(format!("{} must not be null.", name));
    }
    let value = unsafe { CStr::from_ptr(value) };
    value
        .to_str()
        .map(str::to_owned)
        .map_err(|error| format!("{} must be valid UTF-8: {}", name, error))
}

fn replacement_count(value: &serde_json::Value) -> u64 {
    if let Some(count) = value.get("count").and_then(serde_json::Value::as_u64) {
        return count;
    }
    if value.get("ok").and_then(serde_json::Value::as_bool) == Some(true) {
        return 1;
    }
    0
}

#[cfg(test)]
mod tests {
    use rhwp_core::model::paragraph::{CharShapeRef, LineSeg};
    use rhwp_core::DocumentCore;

    #[test]
    fn insert_text_inherits_left_char_shape_at_run_boundary() {
        let mut core = DocumentCore::new_empty();
        core.create_blank_document_native().unwrap();
        core.insert_text_native(0, 0, 0, "ABCD").unwrap();
        core.document_mut()
            .doc_info
            .char_shapes
            .resize_with(2, Default::default);

        {
            let para = &mut core.document_mut().sections[0].paragraphs[0];
            let boundary_start = para.char_offsets[2];
            para.char_shapes = vec![
                CharShapeRef {
                    start_pos: 0,
                    char_shape_id: 0,
                },
                CharShapeRef {
                    start_pos: boundary_start,
                    char_shape_id: 1,
                },
            ];
        }

        core.insert_text_native(0, 0, 2, "X").unwrap();

        let para = &core.document().sections[0].paragraphs[0];
        assert_eq!(para.text, "ABXCD");
        assert_eq!(para.char_shape_id_at(2), Some(0));
        assert_eq!(para.char_shape_id_at(3), Some(1));
        assert_eq!(
            para.char_shapes
                .iter()
                .map(|cs| (cs.start_pos, cs.char_shape_id))
                .collect::<Vec<_>>(),
            vec![(0, 0), (para.char_offsets[3], 1)]
        );
    }

    #[test]
    fn insert_text_preserves_saved_line_metrics() {
        let mut core = DocumentCore::new_empty();
        core.create_blank_document_native().unwrap();
        core.insert_text_native(
            0,
            0,
            0,
            "Hello world repeated words repeated words repeated words",
        )
        .unwrap();

        {
            let para = &mut core.document_mut().sections[0].paragraphs[0];
            para.line_segs = vec![
                LineSeg {
                    text_start: 0,
                    vertical_pos: 3200,
                    line_height: 1600,
                    text_height: 1400,
                    baseline_distance: 1120,
                    line_spacing: 360,
                    column_start: 2400,
                    segment_width: 15000,
                    tag: LineSeg::TAG_SINGLE_SEGMENT_LINE,
                    ..Default::default()
                },
                LineSeg {
                    text_start: 40,
                    vertical_pos: 5160,
                    line_height: 1600,
                    text_height: 1400,
                    baseline_distance: 1120,
                    line_spacing: 360,
                    column_start: 2400,
                    segment_width: 1200,
                    tag: LineSeg::TAG_SINGLE_SEGMENT_LINE,
                    ..Default::default()
                },
            ];
        }

        core.insert_text_native(0, 0, 5, " edited edited edited")
            .unwrap();

        let para = &core.document().sections[0].paragraphs[0];
        let first = para.line_segs.first().expect("edited paragraph line");
        assert!(
            para.line_segs.len() > 1,
            "edited paragraph should wrap using saved segment width"
        );
        assert!(
            para.line_segs.len() < para.text.chars().count() / 2,
            "tiny saved wrap segment should not make nearly every character its own line"
        );
        assert_eq!(first.line_height, 1600);
        assert_eq!(first.text_height, 1400);
        assert_eq!(first.baseline_distance, 1120);
        assert_eq!(first.line_spacing, 360);
        for line in &para.line_segs {
            assert_eq!(line.column_start, 2400);
            assert_eq!(line.segment_width, 15000);
        }
    }
}
