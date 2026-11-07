## 1. Summary

<!--
Provide the smallest, most expressive visual representation of the change
(component tree, call tree, file tree, mermaid diagram, or shaped diff)
along with a brief high-signal explanation.
-->

### Architecture / Visual Shape
```
[Visual Shape / Architecture Flow / Tree of the change]
```

### Affected Components
- `Sources/...`
- `Tests/...`

---

## 2. Evidence

<!--
Provide concrete proof that the implementation works.
Wajib menyertakan Before vs After UI Screenshot jika ada perubahan visual / UI.
-->

### Visual Evidence (UI Changes)
| Before | After |
| :---: | :---: |
| ![Before Screenshot](url_or_placeholder) | ![After Screenshot](url_or_placeholder) |

### Execution Proof (Automated Tests & Build)
```
[Paste unit test execution logs or build verification here]
```

---

## 3. Merge Danger

- **Door Type**: `Two-way door` (reversibel dan aman) / `One-way door` (sulit di-rollback, migrasi data, atau breaking change)
- **Blast Radius**: [Jelaskan potensi dampak sampingan, multi-monitor, backward compatibility, performance]
