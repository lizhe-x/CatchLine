# UI translations

`Localizable.xcstrings` is generated — edit these files, then run `python3 ios/Localization/gen.py`.

- `keys.py`: English source strings, in order (must match the keys Xcode extracts from the Swift code)
- `t1.py`–`t3.py`: translations per language, same order as `keys.py`
- `t4.py`: later additions (index 5 replacement + appended keys)
- `t5.py`: language selection strings (own key list `K5`, appended)
- `t6.py`: silence handling strings (`K6`, appended after `K5`)
- `t7.py`: paywall benefits and billing strings (`K7`, appended after `K6`)

The script refuses to write if a language is missing strings or a `%@` placeholder count differs.
Translations are machine-drafted; have native speakers review before release.
