#include "json.h"

#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

typedef struct {
  const char *p, *end;
  const char *err;
  int depth;
} parser;

static void skip_ws(parser *ps) {
  while (ps->p < ps->end && (*ps->p == ' ' || *ps->p == '\t' || *ps->p == '\n' || *ps->p == '\r'))
    ps->p++;
}

static int hex4(const char *s) {
  int v = 0;
  for (int i = 0; i < 4; i++) {
    char c = s[i];
    v <<= 4;
    if (c >= '0' && c <= '9') v |= c - '0';
    else if (c >= 'a' && c <= 'f') v |= c - 'a' + 10;
    else if (c >= 'A' && c <= 'F') v |= c - 'A' + 10;
    else return -1;
  }
  return v;
}

static size_t put_utf8(char *out, uint32_t cp) {
  if (cp < 0x80) { out[0] = (char)cp; return 1; }
  if (cp < 0x800) { out[0] = (char)(0xC0 | cp >> 6); out[1] = (char)(0x80 | (cp & 0x3F)); return 2; }
  if (cp < 0x10000) {
    out[0] = (char)(0xE0 | cp >> 12); out[1] = (char)(0x80 | ((cp >> 6) & 0x3F));
    out[2] = (char)(0x80 | (cp & 0x3F)); return 3;
  }
  out[0] = (char)(0xF0 | cp >> 18); out[1] = (char)(0x80 | ((cp >> 12) & 0x3F));
  out[2] = (char)(0x80 | ((cp >> 6) & 0x3F)); out[3] = (char)(0x80 | (cp & 0x3F));
  return 4;
}

static char *parse_string(parser *ps, size_t *len_out) {
  // Caller has consumed the opening quote. Decoded text is never longer than the source.
  const char *start = ps->p;
  char *out = malloc((size_t)(ps->end - start) + 1);
  size_t n = 0;
  while (ps->p < ps->end) {
    char c = *ps->p++;
    if (c == '"') {
      out[n] = 0;
      *len_out = n;
      return out;
    }
    if ((unsigned char)c < 0x20) break;
    if (c != '\\') { out[n++] = c; continue; }
    if (ps->p >= ps->end) break;
    char e = *ps->p++;
    switch (e) {
      case '"': out[n++] = '"'; break;
      case '\\': out[n++] = '\\'; break;
      case '/': out[n++] = '/'; break;
      case 'b': out[n++] = '\b'; break;
      case 'f': out[n++] = '\f'; break;
      case 'n': out[n++] = '\n'; break;
      case 'r': out[n++] = '\r'; break;
      case 't': out[n++] = '\t'; break;
      case 'u': {
        if (ps->end - ps->p < 4) goto bad;
        int cp = hex4(ps->p);
        if (cp < 0) goto bad;
        ps->p += 4;
        if (cp >= 0xD800 && cp < 0xDC00 && ps->end - ps->p >= 6 && ps->p[0] == '\\' && ps->p[1] == 'u') {
          int lo = hex4(ps->p + 2);
          if (lo >= 0xDC00 && lo < 0xE000) {
            ps->p += 6;
            cp = 0x10000 + ((cp - 0xD800) << 10) + (lo - 0xDC00);
          }
        }
        // \u0000 would end the C string early; replace it.
        n += put_utf8(out + n, cp == 0 ? 0xFFFD : (uint32_t)cp);
        break;
      }
      default: goto bad;
    }
  }
bad:
  free(out);
  ps->err = "bad string";
  return NULL;
}

static jval *parse_value(parser *ps);

static jval *new_val(jtype t) {
  jval *v = calloc(1, sizeof *v);
  v->type = t;
  return v;
}

static jval *parse_value(parser *ps) {
  skip_ws(ps);
  if (ps->p >= ps->end) { ps->err = "unexpected end"; return NULL; }
  if (++ps->depth > 32) { ps->err = "too deep"; return NULL; }
  jval *v = NULL;
  char c = *ps->p;
  if (c == '{' || c == '[') {
    bool obj = c == '{';
    ps->p++;
    v = new_val(obj ? J_OBJ : J_ARR);
    jval **tail = &v->child;
    skip_ws(ps);
    if (ps->p < ps->end && *ps->p == (obj ? '}' : ']')) {
      ps->p++;
      goto done;
    }
    for (;;) {
      char *key = NULL;
      if (obj) {
        skip_ws(ps);
        size_t klen;
        if (ps->p >= ps->end || *ps->p != '"') { ps->err = "expected key"; goto fail; }
        ps->p++;
        if (!(key = parse_string(ps, &klen))) goto fail;
        skip_ws(ps);
        if (ps->p >= ps->end || *ps->p != ':') { free(key); ps->err = "expected ':'"; goto fail; }
        ps->p++;
      }
      jval *item = parse_value(ps);
      if (!item) { free(key); goto fail; }
      item->key = key;
      *tail = item;
      tail = &item->next;
      skip_ws(ps);
      if (ps->p < ps->end && *ps->p == ',') { ps->p++; continue; }
      if (ps->p < ps->end && *ps->p == (obj ? '}' : ']')) { ps->p++; break; }
      ps->err = "expected ',' or close";
      goto fail;
    }
  } else if (c == '"') {
    ps->p++;
    v = new_val(J_STR);
    if (!(v->str = parse_string(ps, &v->len))) goto fail;
  } else if (ps->end - ps->p >= 4 && !strncmp(ps->p, "true", 4)) {
    v = new_val(J_BOOL); v->boolean = true; ps->p += 4;
  } else if (ps->end - ps->p >= 5 && !strncmp(ps->p, "false", 5)) {
    v = new_val(J_BOOL); ps->p += 5;
  } else if (ps->end - ps->p >= 4 && !strncmp(ps->p, "null", 4)) {
    v = new_val(J_NULL); ps->p += 4;
  } else if (c == '-' || (c >= '0' && c <= '9')) {
    char buf[64];
    size_t n = 0;
    while (ps->p < ps->end && n < sizeof buf - 1 && strchr("+-0123456789.eE", *ps->p)) buf[n++] = *ps->p++;
    buf[n] = 0;
    char *endp;
    v = new_val(J_NUM);
    v->number = strtod(buf, &endp);
    if (*endp) { ps->err = "bad number"; goto fail; }
  } else {
    ps->err = "unexpected character";
    return NULL;
  }
done:
  ps->depth--;
  return v;
fail:
  json_free(v);
  return NULL;
}

jval *json_parse(const char *text, size_t len, const char **err) {
  parser ps = {.p = text, .end = text + len};
  jval *v = parse_value(&ps);
  if (v) {
    skip_ws(&ps);
    if (ps.p != ps.end) { json_free(v); v = NULL; ps.err = "trailing data"; }
  }
  if (!v && err) *err = ps.err ? ps.err : "invalid JSON";
  return v;
}

void json_free(jval *v) {
  while (v) {
    jval *next = v->next;
    json_free(v->child);
    free(v->str);
    free(v->key);
    free(v);
    v = next;
  }
}

jval *json_get(const jval *obj, const char *key) {
  if (!obj || obj->type != J_OBJ) return NULL;
  for (jval *m = obj->child; m; m = m->next)
    if (!strcmp(m->key, key)) return m;
  return NULL;
}

const char *json_str(const jval *obj, const char *key) {
  jval *v = json_get(obj, key);
  return v && v->type == J_STR ? v->str : NULL;
}

bool json_num(const jval *obj, const char *key, double *out) {
  jval *v = json_get(obj, key);
  if (!v || v->type != J_NUM) return false;
  *out = v->number;
  return true;
}

bool json_bool(const jval *obj, const char *key, bool fallback) {
  jval *v = json_get(obj, key);
  return v && v->type == J_BOOL ? v->boolean : fallback;
}

void json_escape(char *buf, size_t cap, size_t *used, const char *s) {
#define PUT(c) do { if (*used + 1 < cap) buf[(*used)++] = (c); } while (0)
  PUT('"');
  for (const unsigned char *p = (const unsigned char *)s; s && *p; p++) {
    if (*p == '"' || *p == '\\') { PUT('\\'); PUT((char)*p); }
    else if (*p < 0x20) {
      char tmp[8];
      snprintf(tmp, sizeof tmp, "\\u%04x", *p);
      for (char *t = tmp; *t; t++) PUT(*t);
    } else PUT((char)*p);
  }
  PUT('"');
  if (*used < cap) buf[*used] = 0;
#undef PUT
}
