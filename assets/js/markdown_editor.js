// Quill + marked + turndown are only needed by the MarkdownEditor hook, so this
// module is loaded on demand (dynamic import) instead of shipping with app.js.
import {marked} from "marked"
import Quill from "quill"
import TurndownService from "turndown"

marked.setOptions({
  breaks: true,
  gfm: true,
})

const markdownTurndown = new TurndownService({
  bulletListMarker: "-",
  codeBlockStyle: "fenced",
  headingStyle: "atx",
})
markdownTurndown.addRule("strikethroughS", {
  filter: ["s", "del"],
  replacement: function (content) {
    return "~~" + content + "~~"
  },
})
markdownTurndown.addRule("underline", {
  filter: ["u"],
  replacement: function (content) {
    return "<u>" + content + "</u>"
  },
})

export const normalizeMarkdown = markdown => markdown.replace(/\r\n/g, "\n").trimEnd()

const normalizeQuillHtml = html => html
  .replace(/<del>/g, "<s>")
  .replace(/<\/del>/g, "</s>")

const quillEditorIsBlank = quill => quill.getText().trim().length === 0

export const renderMarkdownInQuill = (quill, markdown) => {
  const normalizedMarkdown = normalizeMarkdown(markdown || "")

  quill.setContents([])

  if (normalizedMarkdown === "") {
    quill.setText("")
    return
  }

  quill.clipboard.dangerouslyPasteHTML(normalizeQuillHtml(marked.parse(normalizedMarkdown)))
}

export const serializeQuillToMarkdown = quill => {
  if (quillEditorIsBlank(quill)) {
    return ""
  }

  return normalizeMarkdown(
    markdownTurndown
      .turndown(quill.root.innerHTML)
      .replace(/\n{3,}/g, "\n\n")
  )
}

export const createQuill = (surface, placeholder) =>
  new Quill(surface, {
    modules: {
      toolbar: [
        // [{header: [2, 3, false]}],
        ["bold", "italic", "blockquote", "underline", "strike"/*, "code-block", "link"*/],
        // [{list: "ordered"}, {list: "bullet"}],
        ["clean"],
      ],
    },
    placeholder: placeholder || "Write something...",
    theme: "snow",
  })
