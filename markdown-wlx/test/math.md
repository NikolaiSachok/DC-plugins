# Math delimiters

Inline \(a^2+b^2=c^2\) here.

\[e^{i\pi}+1=0\]

$$x = \frac{1}{2}$$

Math in a list:

- inline \(\alpha\) in a bullet
- and \(\beta\) too

| formula | meaning |
| --- | --- |
| \(n!\) | factorial |

A code span must stay literal: `\(code not math\)` and `$$also not$$`.

An escaped backslash-paren pair should stay literal: \\(not math\\).

Prose with a dollar amount: it cost $5 to $10, which must not become math.

Shell docs: use $$ for the pid, then see `echo $$` in the manual.

See footnote \[1\] and reference \[2\] for details.

Regex: match \(a group\) and later a literal \(second group\).

<div align="center">Tight \(y^2\) here and $$z^2$$ too.</div>

Padded display math: $$ x + 1 $$ and bare numbers $$0$$ and $$42$$ render.

Escaped parens glued to a word: select the file\(s\) to open.

Escaped brackets as labels: \[TODO\] and \[x\] stay literal.

<pre><code>Shown, not rendered: $$E=mc^2$$ and \(y^2\).</code></pre>

<div title="a > b">Attribute with a bracket, and \(w^2\) after.</div>

Inline raw HTML: some <code>$$E=mc^2$$</code> and <kbd>\(y^2\)</kbd> stay shown.

<div>if a < b then <pre>$$F=ma$$</pre> and \(v^2\) after.</div>

<div align="center">$$x < y$$ and $$p > q$$ both render.</div>

<kbd>
$$k^2$$
</kbd>

Accented and Cyrillic glue: fiché\(s\) and файл\(ы\) stay text.
