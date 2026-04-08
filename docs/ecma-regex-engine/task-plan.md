# ECMA-262 準拠 Zig 正規表現エンジン — タスク定義書

## 概要

QuickJS libregexp（C, 4300行）を Pure Zig の ECMA-262 準拠正規表現エンジンで完全に置き換える。libc 依存をゼロにし、コードベースの一貫性と保守性を向上させる。

## 前提条件

- ECMA-262 正規表現の仕様を理解していること
- Test262 テストスイートの regex サブセットを取得済みであること
- 現在の QuickJS libregexp の動作を全ての JSON Schema テストスイートで確認済み（920/920 + 1275/1275）

## 設計原則

- **仕様完全準拠**: ECMA-262 の全正規表現機能をサポート。lookahead, lookbehind, 後方参照, Unicode プロパティを含む
- **テスト駆動**: Test262 の regex テストを最初に導入し、テストが通るように実装を進める
- **ベンチマーク駆動**: QuickJS libregexp との性能比較を常時計測。性能が劣化しないことを確認しながら進める
- **段階的置き換え**: EcmaRegex インターフェースは変えず、内部実装だけ差し替える。既存テストが常に通る状態を維持
- **NFA + バックトラッキング**: ECMA-262 は後方参照を含むため DFA では不完全。NFA ベースの実装が必須

---

## Task 1: Test262 regex テストスイートの導入

**対象ファイル**: `build.zig.zon`（依存追加）、`src/test_regex.zig`（新規）

**変更内容**:

1. Test262 リポジトリの regex テスト (`test/built-ins/RegExp/`) を lazy dependency として取得
2. Test262 のテスト形式（JavaScript ファイル）を Zig から実行可能なテストランナーを作成
3. テストケースからパターンと期待結果を抽出し、EcmaRegex.compile + matches で検証
4. 現在の QuickJS libregexp で Test262 regex テストの通過率を計測（ベースライン）

**理由**: 仕様準拠のゴールポストを先に立てる。テストなしに実装すると仕様から逸脱する。

---

## Task 2: QuickJS libregexp のベンチマーク基盤

**対象ファイル**: `src/bench_regex.zig`（新規）

**変更内容**:

1. JSON Schema で実際に使われるパターン群（cspell, package-json, openapi 等）を収集
2. 各パターンに対して compile + match を N 回繰り返すマイクロベンチマーク
3. QuickJS libregexp での計測結果をベースラインとして記録
4. 将来の Zig 実装との比較に使う

**理由**: 性能劣化を検出するため。置き換え後に遅くなっていないことを数値で確認する。

---

## Task 3: パーサー（パターン文字列 → AST）

**対象ファイル**: `src/regex/parser.zig`（新規）

**変更内容**:

ECMA-262 Section 21.2.1 に従って正規表現パターンを AST に変換するパーサーを実装:

- `Disjunction`: `|` で区切られた Alternative の列
- `Alternative`: Term の連結
- `Term`: `Atom` + `Quantifier`
- `Atom`: `.`, `\d`, `\w`, `[...]`, `(...)`, `(?:...)`, `(?=...)`, `(?!...)`, `(?<=...)`, `(?<!...)`, リテラル文字
- `Quantifier`: `*`, `+`, `?`, `{n}`, `{n,}`, `{n,m}`, lazy (`?`) 修飾
- `CharacterClass`: `[abc]`, `[a-z]`, `[^...]`, `\d`, `\D`, `\w`, `\W`, `\s`, `\S`
- `Escape`: `\n`, `\t`, `\r`, `\f`, `\v`, `\0`, `\xHH`, `\uHHHH`, `\u{H...}`
- `BackReference`: `\1`, `\2`, ...
- `Unicode Property`: `\p{...}`, `\P{...}`

AST ノード型:

```zig
const Node = union(enum) {
    literal: u21,           // Unicode codepoint
    dot,                    // . (any char except newline)
    char_class: CharClass,  // [...] or \d, \w, \s etc
    group: Group,           // (...), (?:...), (?=...), etc
    quantifier: Quantifier, // *, +, ?, {n,m}
    alternation: []Node,    // a|b|c
    back_ref: u32,          // \1, \2, ...
    anchor_start,           // ^
    anchor_end,             // $
    word_boundary,          // \b
    non_word_boundary,      // \B
};
```

**理由**: パーサーは全ての後続タスクの土台。AST が正しくないと NFA 構築もマッチングも正しくならない。

---

## Task 4: NFA コンパイラ（AST → NFA 状態遷移グラフ）

**対象ファイル**: `src/regex/compiler.zig`（新規）

**変更内容**:

Thompson の構成法をベースに AST を NFA に変換:

- 各ノード型に対応する NFA フラグメント（開始状態 + 終了状態）を生成
- 連結: フラグメントを直列接続
- 選択 (`|`): epsilon 遷移で分岐
- 量指定子: epsilon 遷移でループ構造
- キャプチャグループ: 開始/終了状態にキャプチャマーカー
- Lookahead/lookbehind: 専用の assertion 状態
- 後方参照: 実行時にキャプチャ結果を参照する特殊遷移

NFA 状態:

```zig
const State = struct {
    transitions: []Transition,
    is_match: bool,
    capture_start: ?u32,  // グループ開始
    capture_end: ?u32,    // グループ終了
    assertion: ?Assertion, // lookahead/lookbehind
};

const Transition = struct {
    target: u32,  // 遷移先状態 ID
    condition: Condition,  // epsilon, char, char_class, back_ref, etc.
};
```

**理由**: NFA はバックトラッキングマッチャーの入力。ECMA-262 の全機能をカバーする NFA 表現が必要。

---

## Task 5: マッチャー（NFA + バックトラッキング）

**対象ファイル**: `src/regex/matcher.zig`（新規）

**変更内容**:

NFA をバックトラッキングで実行するマッチャー:

- 再帰的バックトラッキング（スタックベース、再帰制限付き）
- Greedy / Lazy / Possessive 量指定子の優先順位
- キャプチャグループの結果記録
- Lookahead: 現在位置から先読みし、位置を進めない
- Lookbehind: 現在位置から後読み
- 後方参照: キャプチャ済み文字列との完全一致
- `^`, `$`, `\b` のアンカー処理
- UTF-8 入力のコードポイント単位処理

公開 API:

```zig
pub fn exec(nfa: *const NFA, input: []const u8, start: usize) ?Match {
    // Returns match result with capture groups
}

pub fn test(nfa: *const NFA, input: []const u8) bool {
    // Returns true if any match found
}
```

**理由**: マッチャーが正規表現エンジンの核心。ECMA-262 のマッチングセマンティクス（leftmost-first, greedy by default）に準拠する必要がある。

---

## Task 6: Unicode サポート

**対象ファイル**: `src/regex/unicode.zig`（新規）

**変更内容**:

- Unicode カテゴリ (`\p{L}`, `\p{Nd}` 等) のテーブル
- Case folding テーブル（`/i` フラグ用）
- Unicode Script プロパティ (`\p{Greek}` 等)
- UTF-8 デコード/エンコードヘルパー
- テーブルは comptime で生成するか、データファイルから読み込む

**理由**: ECMA-262 は Unicode プロパティエスケープ (`\p{...}`) をサポートし、`/u` フラグで Unicode モードを有効にする。

---

## Task 7: EcmaRegex インターフェースの差し替え

**対象ファイル**: `src/ecma_regex.zig`（修正）

**変更内容**:

1. QuickJS libregexp の C FFI 呼び出しを Zig 実装に差し替え
2. `compile()`: パーサー → NFA コンパイラを呼ぶ
3. `matches()`: マッチャーを呼ぶ
4. `deinit()`: Zig アロケータで解放
5. 既存の全テスト (920/920 + 1275/1275) が通ることを確認

**理由**: 既存のインターフェースを保つことで、jsonschema.zig の他の部分を変更せずに済む。

---

## Task 8: QuickJS libregexp の完全削除

**対象ファイル**: `src/libregexp/`（ディレクトリ削除）、`build.zig`（C ソース参照削除）

**変更内容**:

1. `src/libregexp/` ディレクトリを削除（8 ファイル, ~250KB）
2. `build.zig` から C ソースファイル参照を削除
3. `link_libc = true` が regex 以外で必要か確認。不要なら削除
4. THIRD_PARTY_LICENSES から QuickJS エントリを削除

**理由**: 外部 C 依存をゼロにし、Pure Zig ライブラリにする。

---

## Task 9: ベンチマーク比較 + 最適化

**対象ファイル**: `src/bench_regex.zig`（更新）

**変更内容**:

1. Task 2 で作ったベンチマークを Zig 実装で再実行
2. QuickJS との性能比較表を作成
3. 遅い箇所があればプロファイルして最適化:
   - 頻出パターン（prefix, literal, simple char class）の fast path
   - NFA 状態の連続メモリ配置
   - バックトラッキングスタックの事前確保
4. jsonschema.zig の warm/cold ベンチマークでデグレがないことを確認

**理由**: QuickJS より遅くなるなら置き換えの意味がない。

---

## 実装順序

```
Task 1 (Test262 テスト導入)
  ↓
Task 2 (ベンチマーク基盤) ── 並行可能
  ↓
Task 3 (パーサー)
  ↓
Task 4 (NFA コンパイラ)
  ↓
Task 5 (マッチャー)
  ↓                    Task 6 (Unicode) ── 並行可能
  ↓                      ↓
Task 7 (インターフェース差し替え)
  ↓
Task 8 (QuickJS 削除)
  ↓
Task 9 (ベンチマーク比較 + 最適化)
```

## スコープ外

- `/g` (global), `/m` (multiline), `/s` (dotAll), `/y` (sticky) フラグの完全実装 — JSON Schema では使用されないが、ECMA-262 準拠のために将来対応可能な設計にする
- Named capture groups (`(?<name>...)`) — ECMA-262 2018+ の機能。基盤は作るが優先度低
- String.prototype.replace 等の JavaScript ランタイム統合 — regex エンジン単体として完結
