// Keyboard, mouse and focus input, applied on the main thread through the
// same libghostty calls the macOS app makes.
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>

#include "host.h"
#include "keymap.h"

static ghostty_input_mods_e held;  // modifiers held by {"action": "press"}
static bool focused = true;

// --- Keys --------------------------------------------------------------------

#define M_SHIFT GHOSTTY_MODS_SHIFT
#define M_CTRL GHOSTTY_MODS_CTRL
#define M_ALT GHOSTTY_MODS_ALT
#define M_SUPER GHOSTTY_MODS_SUPER

static const struct {
  const char *name;
  int mod;
} MOD_NAMES[] = {
    {"shift", M_SHIFT}, {"ctrl", M_CTRL},   {"control", M_CTRL}, {"alt", M_ALT},       {"opt", M_ALT},
    {"option", M_ALT},  {"super", M_SUPER}, {"cmd", M_SUPER},    {"command", M_SUPER}, {"meta", M_SUPER},
};

// The four modifiers in press order, with the key that carries each.
static const struct {
  int mod;
  const char *code;
} MOD_KEYS[] = {{M_SHIFT, "ShiftLeft"}, {M_CTRL, "ControlLeft"}, {M_ALT, "AltLeft"}, {M_SUPER, "MetaLeft"}};

// X keysyms and other spellings, to W3C codes.
static const struct {
  const char *alias, *code;
} KEY_ALIASES[] = {
    {"Return", "Enter"},       {"return", "Enter"},          {"KP_Enter", "NumpadEnter"},
    {"BackSpace", "Backspace"}, {"bs", "Backspace"},          {"Up", "ArrowUp"},
    {"Down", "ArrowDown"},     {"Left", "ArrowLeft"},        {"Right", "ArrowRight"},
    {"Prior", "PageUp"},       {"Next", "PageDown"},         {"Page_Up", "PageUp"},
    {"Page_Down", "PageDown"}, {"pageup", "PageUp"},         {"pagedown", "PageDown"},
    {"esc", "Escape"},         {"del", "Delete"},            {"space", "Space"},
    {"Shift_L", "ShiftLeft"},  {"Shift_R", "ShiftRight"},    {"Control_L", "ControlLeft"},
    {"Control_R", "ControlRight"}, {"Alt_L", "AltLeft"},     {"Alt_R", "AltRight"},
    {"Super_L", "MetaLeft"},   {"Super_R", "MetaRight"},     {"Meta_L", "MetaLeft"},
    {"Meta_R", "MetaRight"},
};

// US layout: the key and shift state that type each printable character.
static const struct {
  char c;
  const char *code;
  bool shift;
} US[] = {
    {' ', "Space", 0},       {'-', "Minus", 0},        {'_', "Minus", 1},        {'=', "Equal", 0},
    {'+', "Equal", 1},       {'[', "BracketLeft", 0},  {'{', "BracketLeft", 1},  {']', "BracketRight", 0},
    {'}', "BracketRight", 1}, {'\\', "Backslash", 0},  {'|', "Backslash", 1},    {';', "Semicolon", 0},
    {':', "Semicolon", 1},   {'\'', "Quote", 0},       {'"', "Quote", 1},        {',', "Comma", 0},
    {'<', "Comma", 1},       {'.', "Period", 0},       {'>', "Period", 1},       {'/', "Slash", 0},
    {'?', "Slash", 1},       {'`', "Backquote", 0},    {'~', "Backquote", 1},    {'1', "Digit1", 0},
    {'!', "Digit1", 1},      {'2', "Digit2", 0},       {'@', "Digit2", 1},       {'3', "Digit3", 0},
    {'#', "Digit3", 1},      {'4', "Digit4", 0},       {'$', "Digit4", 1},       {'5', "Digit5", 0},
    {'%', "Digit5", 1},      {'6', "Digit6", 0},       {'^', "Digit6", 1},       {'7', "Digit7", 0},
    {'&', "Digit7", 1},      {'8', "Digit8", 0},       {'*', "Digit8", 1},       {'9', "Digit9", 0},
    {'(', "Digit9", 1},      {'0', "Digit0", 0},       {')', "Digit0", 1},
};

// Ghostty takes native keycodes: macOS virtual keycodes, XKB keycodes on Linux.
#ifdef __APPLE__
#define NATIVE(entry) ((entry).mac)
#define NO_KEYCODE 0xFFFFu
#else
#define NATIVE(entry) ((entry).xkb)
#define NO_KEYCODE 0u
#endif

typedef struct {
  const char *code;  // W3C code, e.g. "KeyA"
  int keycode;  // native keycode, -1 for none
  int modifier;  // the modifier this key is, if any
  char plain[8], shifted[8];  // text on a US layout, empty for none
  uint32_t unshifted;  // codepoint with no modifiers
} keyinfo;

static int keycode_for(const char *code) {
  for (size_t i = 0; i < sizeof KEYMAP / sizeof *KEYMAP; i++)
    if (!strcmp(code, KEYMAP[i].code)) return NATIVE(KEYMAP[i]) == NO_KEYCODE ? -1 : (int)NATIVE(KEYMAP[i]);
  return -1;
}

static void fill_key(keyinfo *k, const char *code) {
  memset(k, 0, sizeof *k);
  k->code = code;
  k->keycode = keycode_for(code);
  if (!strncmp(code, "Key", 3) && code[3] >= 'A' && code[3] <= 'Z' && !code[4]) {
    k->plain[0] = (char)(code[3] + 32);
    k->shifted[0] = code[3];
  }
  for (size_t i = 0; i < sizeof US / sizeof *US; i++)
    if (!strcmp(US[i].code, code)) (US[i].shift ? k->shifted : k->plain)[0] = US[i].c;
  k->unshifted = (unsigned char)k->plain[0];
  if (!strcmp(code, "Enter") || !strcmp(code, "NumpadEnter")) k->unshifted = '\r';
  else if (!strcmp(code, "Tab")) k->unshifted = '\t';
  else if (!strcmp(code, "Backspace")) k->unshifted = 0x7f;
  else if (!strcmp(code, "Escape")) k->unshifted = 0x1b;
  if (!strncmp(code, "Shift", 5)) k->modifier = M_SHIFT;
  else if (!strncmp(code, "Control", 7)) k->modifier = M_CTRL;
  else if (!strncmp(code, "Alt", 3)) k->modifier = M_ALT;
  else if (!strncmp(code, "Meta", 4)) k->modifier = M_SUPER;
  // Right-hand modifiers also set their side bit, as the macOS app does.
  if (k->modifier && strstr(code, "Right")) k->modifier |= k->modifier << 6;
}

// Resolves a key name: one character (US layout), a W3C code, a Ghostty
// key name or an X keysym. *implied gets shift for characters that need it.
static bool resolve_key(const char *name, keyinfo *k, int *implied) {
  *implied = 0;
  if (name[0] && !name[1]) {
    char c = name[0];
    if ((c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z')) {
      char code[5] = {'K', 'e', 'y', (char)(c & ~0x20), 0};
      for (size_t i = 0; i < sizeof KEYMAP / sizeof *KEYMAP; i++)
        if (!strcmp(code, KEYMAP[i].code)) fill_key(k, KEYMAP[i].code);
      *implied = c <= 'Z' ? M_SHIFT : 0;
      return true;
    }
    for (size_t i = 0; i < sizeof US / sizeof *US; i++)
      if (US[i].c == c) {
        fill_key(k, US[i].code);
        *implied = US[i].shift ? M_SHIFT : 0;
        return true;
      }
  }
  for (size_t i = 0; i < sizeof KEY_ALIASES / sizeof *KEY_ALIASES; i++)
    if (!strcmp(name, KEY_ALIASES[i].alias)) name = KEY_ALIASES[i].code;
  char digit[8];
  if (!strncasecmp(name, "digit", 5) && name[5] == '_') {
    snprintf(digit, sizeof digit, "Digit%s", name + 6);
    name = digit;
  }
  for (size_t i = 0; i < sizeof KEYMAP / sizeof *KEYMAP; i++)
    if (!strcmp(name, KEYMAP[i].code) || !strcasecmp(name, KEYMAP[i].name)) {
      fill_key(k, KEYMAP[i].code);
      return true;
    }
  return false;
}

// One key event shaped like the macOS app's (NSEvent+Extension.swift):
// text never starts with a control character, and control and command never
// count as consumed. Option acts as alt, so it isn't consumed either.
static bool key_event(ghostty_input_action_e action, const keyinfo *k, int mods, const char *text) {
  if (!text && action != GHOSTTY_ACTION_RELEASE) text = (mods & M_SHIFT) && k->shifted[0] ? k->shifted : k->plain;
  if (action == GHOSTTY_ACTION_RELEASE) text = NULL;
  ghostty_input_key_s ev = {
      .action = action,
      .mods = (ghostty_input_mods_e)mods,
      .consumed_mods = (ghostty_input_mods_e)(mods & (M_SHIFT | GHOSTTY_MODS_SHIFT_RIGHT)),
      .keycode = k->keycode < 0 ? NO_KEYCODE : (uint32_t)k->keycode,
      .text = text && text[0] && (unsigned char)text[0] >= 0x20 && text[0] != 0x7f ? text : NULL,
      .unshifted_codepoint = k->unshifted,
      .composing = false,
  };
  return ghostty_surface_key(surface, ev);
}

// Presses each modifier in `mods` not already held, as its own key.
// Returns the modifiers it pressed.
static int press_mods(int mods) {
  int pressed = 0;
  for (size_t i = 0; i < 4; i++) {
    if (!(mods & MOD_KEYS[i].mod) || (held & MOD_KEYS[i].mod)) continue;
    keyinfo k;
    fill_key(&k, MOD_KEYS[i].code);
    pressed |= MOD_KEYS[i].mod;
    key_event(GHOSTTY_ACTION_PRESS, &k, held | pressed, NULL);
  }
  return pressed;
}

static void release_mods(int pressed) {
  for (size_t i = 4; i-- > 0;) {
    if (!(pressed & MOD_KEYS[i].mod)) continue;
    keyinfo k;
    fill_key(&k, MOD_KEYS[i].code);
    pressed &= ~MOD_KEYS[i].mod;
    key_event(GHOSTTY_ACTION_RELEASE, &k, held | pressed, NULL);
  }
}

static int parse_mod_list(const jval *v, const char **bad) {
  int mods = 0;
  if (!v) return 0;
  const jval *one = v->type == J_STR ? v : NULL;
  const jval *it = v->type == J_ARR ? v->child : one;
  if (!it && v->type != J_ARR) {
    *bad = "mods is a string or an array of strings";
    return 0;
  }
  for (; it; it = one ? NULL : it->next) {
    if (it->type != J_STR) {
      *bad = "mods is a string or an array of strings";
      return 0;
    }
    // A string may itself be "ctrl+shift".
    char *copy = strdup(it->str), *save = NULL;
    for (char *tok = strtok_r(copy, "+", &save); tok; tok = strtok_r(NULL, "+", &save)) {
      size_t i = 0;
      while (i < sizeof MOD_NAMES / sizeof *MOD_NAMES && strcasecmp(tok, MOD_NAMES[i].name)) i++;
      if (i == sizeof MOD_NAMES / sizeof *MOD_NAMES) *bad = "unknown modifier";
      else mods |= MOD_NAMES[i].mod;
    }
    free(copy);
  }
  return mods;
}

typedef enum { TAP, PRESS, RELEASE, REPEAT } key_action;

// Sends one key spec in keybind syntax ("ctrl+shift+t", "Return", "A").
static const char *send_spec(const char *spec, key_action action, const char *text, bool *consumed) {
  char buf[128];
  snprintf(buf, sizeof buf, "%s", spec);
  // The last '+'-separated token is the key; a trailing "+" is the plus key.
  char *key = buf;
  size_t len = strlen(buf);
  int mods = 0;
  char *last_plus = len > 1 && buf[len - 1] == '+' && buf[len - 2] == '+' ? buf + len - 2 : strrchr(buf, '+');
  if (last_plus && last_plus != buf) {
    *last_plus = 0;
    key = last_plus + 1;
    const char *bad = NULL;
    jval mods_val = {.type = J_STR, .str = buf};
    mods = parse_mod_list(&mods_val, &bad);
    if (bad) return bad;
  }
  keyinfo k;
  int implied;
  if (!resolve_key(key, &k, &implied)) return "unknown key";
  mods |= implied;

  int pressed;
  switch (action) {
    case TAP:
      pressed = press_mods(mods);
      *consumed = key_event(GHOSTTY_ACTION_PRESS, &k, held | mods | k.modifier, text);
      key_event(GHOSTTY_ACTION_RELEASE, &k, held | mods, NULL);
      release_mods(pressed);
      break;
    case PRESS:
      held |= press_mods(mods);
      *consumed = key_event(GHOSTTY_ACTION_PRESS, &k, held | k.modifier, text);
      held |= k.modifier;
      break;
    case RELEASE:
      held &= ~k.modifier;
      *consumed = key_event(GHOSTTY_ACTION_RELEASE, &k, held, NULL);
      release_mods(mods & held);
      held &= ~mods;
      break;
    case REPEAT:
      *consumed = key_event(GHOSTTY_ACTION_REPEAT, &k, held | mods, text);
      break;
  }
  return NULL;
}

static void publish_state(void);

static void reply(op *o, int status, const char *error) {
  publish_state();
  o->status = status;
  if (error) {
    size_t used = (size_t)snprintf(o->out, o->cap, "{\"ok\":false,\"error\":");
    json_escape(o->out, o->cap, &used, error);
    snprintf(o->out + used, o->cap - used, "}");
  } else {
    // N is the last frame drawn before this input, so GET /frame?after=N
    // waits for one drawn after it.
    snprintf(o->out, o->cap, "{\"ok\":true,\"frame\":%llu}", (unsigned long long)frames_drawn_seq());
  }
}

void op_key(void *ctx) {
  op *o = ctx;
  const char *a = json_str(o->body, "action");
  key_action action = TAP;
  if (a && !strcmp(a, "press")) action = PRESS;
  else if (a && !strcmp(a, "release")) action = RELEASE;
  else if (a && !strcmp(a, "repeat")) action = REPEAT;
  else if (a && strcmp(a, "tap")) return reply(o, 400, "action is tap, press, release or repeat");
  const char *text = json_str(o->body, "text");
  const jval *keys = json_get(o->body, "key");
  if (!keys || (keys->type != J_STR && keys->type != J_ARR)) return reply(o, 400, "key is a string or an array");
  bool consumed = false;
  for (const jval *k = keys->type == J_STR ? keys : keys->child; k; k = keys->type == J_STR ? NULL : k->next) {
    if (k->type != J_STR) return reply(o, 400, "key is a string or an array");
    const char *err = send_spec(k->str, action, text, &consumed);
    if (err) return reply(o, 400, err);
  }
  reply(o, 200, NULL);
}

static uint32_t utf8_next(const char **p) {
  const unsigned char *s = (const unsigned char *)*p;
  uint32_t cp;
  int n;
  if (s[0] < 0x80) cp = s[0], n = 1;
  else if ((s[0] & 0xE0) == 0xC0 && s[1]) cp = (uint32_t)(s[0] & 0x1F) << 6 | (s[1] & 0x3F), n = 2;
  else if ((s[0] & 0xF0) == 0xE0 && s[1] && s[2])
    cp = (uint32_t)(s[0] & 0x0F) << 12 | (uint32_t)(s[1] & 0x3F) << 6 | (s[2] & 0x3F), n = 3;
  else if ((s[0] & 0xF8) == 0xF0 && s[1] && s[2] && s[3])
    cp = (uint32_t)(s[0] & 0x07) << 18 | (uint32_t)(s[1] & 0x3F) << 12 | (uint32_t)(s[2] & 0x3F) << 6 | (s[3] & 0x3F),
    n = 4;
  else cp = 0xFFFD, n = 1;
  *p += n;
  return cp;
}

void op_type(void *ctx) {
  op *o = ctx;
  const char *text = json_str(o->body, "text");
  if (!text) return reply(o, 400, "text is required");
  bool consumed;
  for (const char *p = text; *p;) {
    const char *start = p;
    uint32_t cp = utf8_next(&p);
    if (cp == '\n' || cp == '\r') send_spec("Enter", TAP, NULL, &consumed);
    else if (cp == '\t') send_spec("Tab", TAP, NULL, &consumed);
    else if (cp == 0x7f || cp == '\b') send_spec("Backspace", TAP, NULL, &consumed);
    else if (cp == 0x1b) send_spec("Escape", TAP, NULL, &consumed);
    else if (cp >= 1 && cp <= 26) {
      char spec[8] = {'c', 't', 'r', 'l', '+', (char)('a' + cp - 1), 0};
      send_spec(spec, TAP, NULL, &consumed);
    } else if (cp < 0x20) {
      continue;
    } else if (cp < 0x7f) {
      char spec[2] = {(char)cp, 0};
      send_spec(spec, TAP, NULL, &consumed);
    } else {
      // Not on a US keyboard: committed text from no particular key.
      char buf[8] = {0};
      memcpy(buf, start, (size_t)(p - start));
      keyinfo k = {.code = "", .keycode = -1, .unshifted = cp};
      key_event(GHOSTTY_ACTION_PRESS, &k, held, buf);
      key_event(GHOSTTY_ACTION_RELEASE, &k, held, NULL);
    }
  }
  reply(o, 200, NULL);
}

// --- Mouse -------------------------------------------------------------------

static const char *mouse_one(const jval *m) {
  if (!m || m->type != J_OBJ) return "each mouse event is an object";
  const char *bad = NULL;
  int mods = parse_mod_list(json_get(m, "mods"), &bad);
  if (bad) return bad;
  const char *action = json_str(m, "action");
  if (!action) action = "move";
  double x, y;
  bool has_x = json_num(m, "x", &x), has_y = json_num(m, "y", &y);
  if (has_x != has_y) return "give both x and y";
  if (!has_x && !strcmp(action, "move")) return "move needs x and y";

  static const char *const BUTTONS[] = {"unknown", "left", "right", "middle", "four", "five", "six",
                                        "seven", "eight", "nine", "ten", "eleven"};
  const char *bname = json_str(m, "button");
  int button = GHOSTTY_MOUSE_LEFT;
  if (bname) {
    button = -1;
    for (int i = 1; i < (int)(sizeof BUTTONS / sizeof *BUTTONS); i++)
      if (!strcmp(bname, BUTTONS[i])) button = i;
    if (button < 0) return "unknown button";
  }
  double count = 1;
  json_num(m, "count", &count);
  if (strcmp(action, "move") && strcmp(action, "press") && strcmp(action, "release") && strcmp(action, "click") &&
      strcmp(action, "scroll") && strcmp(action, "leave"))
    return "action is move, press, release, click, scroll or leave";

  int pressed = press_mods(mods);
  int all = held | mods;
  // Frame pixels, top-left origin, to the view's points.
  if (has_x) ghostty_surface_mouse_pos(surface, x / opt.scale, y / opt.scale, (ghostty_input_mods_e)all);
  ghostty_input_mouse_button_e b = (ghostty_input_mouse_button_e)button;
  if (!strcmp(action, "press")) {
    ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_PRESS, b, (ghostty_input_mods_e)all);
  } else if (!strcmp(action, "release")) {
    ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_RELEASE, b, (ghostty_input_mods_e)all);
  } else if (!strcmp(action, "click")) {
    // Ghostty counts double and triple clicks itself, by timing.
    for (int i = 0; i < (int)count; i++) {
      ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_PRESS, b, (ghostty_input_mods_e)all);
      ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_RELEASE, b, (ghostty_input_mods_e)all);
    }
  } else if (!strcmp(action, "scroll")) {
    double dx = 0, dy = 0;
    json_num(m, "dx", &dx);
    json_num(m, "dy", &dy);
    // Bit 0 of the scroll mods marks precise (trackpad) deltas.
    ghostty_surface_mouse_scroll(surface, dx, dy, json_bool(m, "precise", false) ? 1 : 0);
  } else if (!strcmp(action, "leave")) {
    // What the macOS app sends from mouseExited.
    ghostty_surface_mouse_pos(surface, -1, -1, (ghostty_input_mods_e)all);
  }
  release_mods(pressed);
  return NULL;
}

void op_mouse(void *ctx) {
  op *o = ctx;
  const jval *b = o->body;
  for (const jval *m = b->type == J_ARR ? b->child : b; m; m = b->type == J_ARR ? m->next : NULL) {
    const char *err = mouse_one(m);
    if (err) return reply(o, 400, err);
  }
  reply(o, 200, NULL);
}

// --- Focus, actions, quit, info ------------------------------------------------

void op_focus(void *ctx) {
  op *o = ctx;
  const jval *f = json_get(o->body, "focused");
  if (!f || f->type != J_BOOL) return reply(o, 400, "focused is true or false");
  focused = f->boolean;
  ghostty_surface_set_focus(surface, focused);
  reply(o, 200, NULL);
}

void op_action(void *ctx) {
  op *o = ctx;
  const char *action = json_str(o->body, "action");
  if (!action) return reply(o, 400, "action is required");
  bool performed = ghostty_surface_binding_action(surface, action, strlen(action));
  publish_state();
  o->status = 200;
  snprintf(o->out, o->cap, "{\"ok\":true,\"performed\":%s,\"frame\":%llu}", performed ? "true" : "false",
           (unsigned long long)frames_drawn_seq());
}

void op_quit(void *ctx) {
  platform_stop();
  reply(ctx, 200, NULL);
}

static pthread_mutex_t state_mu = PTHREAD_MUTEX_INITIALIZER;
static bool shared_focused = true;
static int shared_held;

// Ops run on the main thread; publish what /status reports after each one.
static void publish_state(void) {
  pthread_mutex_lock(&state_mu);
  shared_focused = focused;
  shared_held = held;
  pthread_mutex_unlock(&state_mu);
}

void input_state_json(char *buf, size_t cap, size_t *used) {
  pthread_mutex_lock(&state_mu);
  bool f = shared_focused;
  int h = shared_held;
  pthread_mutex_unlock(&state_mu);
  static const char *const NAMES[] = {"shift", "ctrl", "alt", "super"};
  *used += (size_t)snprintf(buf + *used, cap - *used, "\"focused\":%s,\"held_mods\":[", f ? "true" : "false");
  bool first = true;
  for (int i = 0; i < 4; i++)
    if (h & MOD_KEYS[i].mod) {
      *used += (size_t)snprintf(buf + *used, cap - *used, "%s\"%s\"", first ? "" : ",", NAMES[i]);
      first = false;
    }
  *used += (size_t)snprintf(buf + *used, cap - *used, "]");
}
