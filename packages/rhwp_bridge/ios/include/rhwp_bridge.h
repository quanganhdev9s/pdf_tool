#ifndef RHWP_BRIDGE_H
#define RHWP_BRIDGE_H

#include <stdbool.h>
#include <stdint.h>

char *rhwp_bridge_version(void);
char *rhwp_bridge_open_path(const char *input_path);
char *rhwp_bridge_close(uint64_t handle);
char *rhwp_bridge_page_count(uint64_t handle);
char *rhwp_bridge_extract_text(uint64_t handle);
char *rhwp_bridge_render_page_svg(uint64_t handle, uint32_t page_index);
char *rhwp_bridge_hit_test(uint64_t handle, uint32_t page_index, double x, double y);
char *rhwp_bridge_get_cursor_rect(
    uint64_t handle,
    uint32_t section_index,
    uint32_t paragraph_index,
    uint32_t char_offset);
char *rhwp_bridge_insert_text(
    uint64_t handle,
    uint32_t section_index,
    uint32_t paragraph_index,
    uint32_t char_offset,
    const char *text);
char *rhwp_bridge_delete_text(
    uint64_t handle,
    uint32_t section_index,
    uint32_t paragraph_index,
    uint32_t char_offset,
    uint32_t count);
char *rhwp_bridge_split_paragraph(
    uint64_t handle,
    uint32_t section_index,
    uint32_t paragraph_index,
    uint32_t char_offset);
char *rhwp_bridge_merge_paragraph(
    uint64_t handle,
    uint32_t section_index,
    uint32_t paragraph_index);
char *rhwp_bridge_replace_text(
    uint64_t handle,
    const char *find,
    const char *replacement,
    bool case_sensitive,
    bool replace_all);
char *rhwp_bridge_export(uint64_t handle, const char *output_path);
void rhwp_bridge_string_free(char *value);

#endif
