;;; org-translate.el --- Org-based translation environment  -*- lexical-binding: t; -*-

;; Copyright (C) 2020  Free Software Foundation, Inc.

;; Version: 0
;; Package-Requires: ((emacs "25.1") (org "9.1"))

;; Author: Eric Abrahamsen <eric@ericabrahamsen.net>
;; Maintainer: Eric Abrahamsen <eric@ericabrahamsen.net>

;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <https://www.gnu.org/licenses/>.

;;; Commentary:

;; This library contains the `org-translate-mode' minor mode to be
;; used on top of Org, providing translation-related functionality.
;; It is not a full-fledged CAT tool.  It essentially does two things:
;; manages segmentation correspondences between the source text and
;; the translation, and manages a glossary which can be used for
;; automatic translation, displaying previous usages, etc.

;; Currently assumes a single file holding a single translation
;; project, with three separate headings for source text, translation,
;; and glossary (other headings will be ignored).  Each translation
;; project has five local settings, each of which also has a global
;; default value.  The first three settings are used to locate the org
;; subtrees representing source text, translation text, and glossary.
;; The fourth setting defines the segmentation strategy: the source
;; text can be segmented by sentence, paragraph, or regular
;; expression.  The fifth setting determines the character to be used
;; to delimit segments.

;; While translating, use "C-M-n" to start a new segment in the
;; translation text.  "C-M-b" and "C-M-f" will move forward and back
;; between segments, maintaining the correspondence with the source
;; text.  If the source text highlighting gets "lost", reset it with
;; "C-M-t".  To add a new glossary item, move to the source window,
;; put the region on the new item, and use M-x ogt-add-glossary-item.
;; In the translation text, add a translation of the next glossary
;; item with "C-M-y".

;; Translation projects can optionally be defined and configured in
;; the option `ogt-translation-projects' (see docstring for details)
;; though this is only useful if you're working on multiple projects
;; with different settings.

;; The functions `ogt-start-translating' and `ogt-stop-translating'
;; can be used to start and stop a translation session.  The first use
;; of the latter command will save the project in your bookmarks file,
;; after which `ogt-start-translating' will offer the project to work
;; on.

;; TODO:

;; - Generalize the code to work in text-mode as well as Org,
;;   using 2C-mode instead of Org subtrees.
;; - Support multi-file translation projects.
;; - Import/export TMX translation databases.
;; - Provide for other glossary backends: eieio-persistent, xml,
;;   sqlite, etc.
;; - Provide integration with `org-clock': set a custom property on a
;;   TODO heading indicating that it represents a translation project.
;;   Clocking in both starts the clock, and sets up the translation
;;   buffers.  Something like that.

;;; Code:

(require 'bookmark)
(require 'ox)

(defgroup org-translate nil
  "Customizations for the org-translate library."
  :group 'text)

(defcustom ogt-default-source-locator '(tag . "source")
  "Default method for locating the source-language subtree.
The value should be a cons of (TYPE . MATCHER), where TYPE is a
locator type, as a symbol, and MATCHER is a string or other
specification.  `org-translate-mode' will identify the subtree
representing the source-language text by locating the first
heading where MATCHER matches the TYPE of the heading's
data. Valid TYPEs are:

`tag': Match heading tags.
`id': Match the heading ID.
`property': Match an arbitrary other property.  MATCHER should be
            a further cons of two strings: the property name and
            value.
`heading': Match heading text.

Once the heading is located, it will be tracked by its ID
property."
  :type '(choice
	  (cons :tag "Tag" (const tag) string)
	  (cons :tag "ID" (const id) string)
	  (cons :tag "Property" (const property)
		(cons (string :tag "Property name")
		      (string :tag "Property value")))
	  (cons :tag "Heading text" (const heading) string)))

(defcustom ogt-default-translation-locator '(tag . "translation")
  "Default method for locating the translation subtree.
The value should be a cons of (TYPE . MATCHER), where TYPE is a
locator type, as a symbol, and MATCHER is a string or other
specification.  `org-translate-mode' will identify the subtree
representing the source-language text by locating the first
heading where MATCHER matches the TYPE of the heading's
data. Valid TYPEs are:

`tag': Match heading tags.
`ID': Match the heading ID.
`property': Match an arbitrary other property.  MATCHER should be
            a further cons of two strings: the property name and
            value.
`heading': Match heading text.

Once the heading is located, it will be tracked by its ID
property."
  :type '(choice
	  (cons :tag "Tag" (const tag) string)
	  (cons :tag "ID" (const id) string)
	  (cons :tag "Property" (const property)
		(cons (string :tag "Property name")
		      (string :tag "Property value")))
	  (cons :tag "Heading text" (const heading) string)))

(defcustom ogt-default-glossary-locator '(heading . "glossary")
  "Default method for locating the glossary subtree.
The value should be a cons of (TYPE . MATCHER), where TYPE is a
locator type, as a symbol, and MATCHER is a string or other
specification.  `org-translate-mode' will identify the subtree
representing the source-language text by locating the first
heading where MATCHER matches the TYPE of the heading's
data. Valid TYPEs are:

`tag': Match heading tags.
`ID': Match the heading ID.
`property': Match an arbitrary other property.  MATCHER should be
            a further cons of two strings: the property name and
            value.
`heading': Match heading text (case-insensitively).

Once the heading is located, it will be tracked by its ID
property."
  :type '(choice
	  (cons :tag "Tag" (const tag) string)
	  (cons :tag "ID" (const id) string)
	  (cons :tag "Property" (const property)
		(cons (string :tag "Property name")
		      (string :tag "Property value")))
	  (cons :tag "Heading text" (const heading) string)))

;; `org-block-regexp', `org-table-any-line-regexp',
;; `org-heading-regexp' `page-delimiter'... Hmm, maybe we should be
;; walking through using the org parser instead?
(defcustom ogt-default-segmentation-strategy 'sentence
  "Default strategy for segmenting source/target text.
Value can be one of symbols `sentence' or `paragraph', in which
case the buffer-local definitions of sentence and paragraph will
be used.  It can also be a regular expression.

Org headings, lists, tables, etc, as well as the value of
`page-delimiter', will always delimit segments."
  :type '(choice (const :tag "Sentence" sentence)
		 (const :tag "Paragraph" paragraph)
		 regexp))

(defcustom ogt-default-segmentation-character 29
  ;; INFORMATION SEPARATOR THREE, aka "group separator"
  "Default character used to delimit segments."
  :type 'character)

;(defface ogt-source-segment-face '())

(defcustom ogt-translation-projects nil
  "Alist of active translation projects.
Keys are identifying string for use in completion.  Values are
plists specifying options for that project.  Valid options are
:file, :seg-strategy, :seg-character, :source, :translation, and
:glossary.  The last three values can be specified as a string
ID, or as a \"locator\" as in, for instance,
`ogt-default-source-locator'."
  :type 'list)

(defvar-local ogt-source-heading nil
  "ID of the source-text heading in this file.")

(defvar-local ogt-translation-heading nil
  "ID of the translation heading in this file.")

(defvar-local ogt-glossary-heading nil
  "ID of the glossary heading in this file.")

(defvar-local ogt-segmentation-strategy nil
  "Segmentation strategy in this file.")

(defvar-local ogt-segmentation-character nil
  "Segmentation character in this file.")

(defvar-local ogt-this-project-name nil
  "String name of the current translation project, if any.
If `ogt-translation-projects' is not used, this will be nil.")

(defvar-local ogt-glossary-table nil
  "Hash table holding original<->translation relations.
Keys are glossary heading IDs.  Values are an alist holding
source terms and translation terms.")

(defvar-local ogt-source-window nil
  "Pointer to window on source text.")

(defvar-local ogt-translation-window nil
  "Pointer to window on translation text.")

(defvar-local ogt-probable-source-location nil
  "Marker at point's corresponding location in source text.
Called \"probable\" as it is placed heuristically, updated very
fragilely, and deleted and re-set with abandon.")

(defvar-local ogt-source-segment-overlay nil
  "Overlay on the current source segment.")

(org-link-set-parameters
 "trans"
 :follow #'ogt-follow-link
 ;; Give it a :keymap!  Very nice.
 :export #'ogt-export-link)

(defun ogt-follow-link (link)
  (org-id-open link))

(defun ogt-export-link (_path desc _backend)
  "Export a translation link.
By default, just remove it."
  desc)

(defvar org-translate-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "C-M-f") #'ogt-forward-segment)
    (define-key map (kbd "C-M-b") #'ogt-backward-segment)
    (define-key map (kbd "C-M-n") #'ogt-new-segment)
    (define-key map (kbd "C-M-t") #'ogt-update-source-location)
    (define-key map (kbd "C-M-y") #'ogt-insert-glossary-translation)
    map))

(define-minor-mode org-translate-mode
  "Minor mode for using an Org file as a translation project."
  nil " Translate" nil
  (if (null org-translate-mode)
      (progn
	(setq ogt-source-heading nil
	      ogt-translation-heading nil
	      ogt-glossary-heading nil
	      ogt-segmentation-strategy nil
	      ogt-segmentation-character nil
	      ogt-glossary-table nil)
	(move-marker ogt-probable-source-location nil)
	(delete-overlay ogt-source-segment-overlay))
    (unless (derived-mode-p 'org-mode)
      (user-error "Only applicable in Org files."))
    (let* ((this-project (or ogt-this-project-name
			     (when ogt-translation-projects
			       (let* ((f-name (buffer-file-name)))
				 (seq-find
				  (lambda (elt)
				    (file-equal-p
				     f-name (plist-get (cdr elt) :file)))
				  ogt-translation-projects)))))
	   (this-plist (when this-project
			 (alist-get this-project ogt-translation-projects))))
      (setq ogt-source-heading (or (plist-get this-plist :source)
				   (ogt-locate-heading
				    ogt-default-source-locator))
	    ogt-translation-heading (or (plist-get this-plist :translation)
					(ogt-locate-heading
					 ogt-default-translation-locator))
	    ogt-glossary-heading (or (plist-get this-plist :glossary)
				     (ogt-locate-heading
				      ogt-default-glossary-locator))
	    ogt-segmentation-strategy (or (plist-get this-plist :seg-strategy)
					  ogt-default-segmentation-strategy)
	    ogt-segmentation-character (or (plist-get this-plist :seg-character)
					   ogt-default-segmentation-character)
	    ogt-glossary-table (make-hash-table :size 500 :test #'equal)
	    ogt-probable-source-location (make-marker)
	    ogt-source-segment-overlay (make-overlay (point) (point)))
      (push #'ogt-export-remove-segmenters org-export-filter-body-functions)
      (overlay-put ogt-source-segment-overlay
		   'face 'highlight)
      ;; Doesn't actually delete it, just makes it "inactive" until we
      ;; know where to put it.
      (delete-overlay ogt-source-segment-overlay)
      (delete-other-windows)
      (org-show-all)
      (save-excursion
	(ogt-goto-heading 'source)
	(when (and (save-restriction
		     (org-narrow-to-subtree)
		     (null (re-search-forward
			    (string ogt-segmentation-character) nil t)))
		   (yes-or-no-p
		    "Project not yet segmented, segment now?"))
	  (ogt-segment-project))
	(dolist (location '(source translation))
	  (ogt-goto-heading location)
	  (save-restriction
	    (org-narrow-to-subtree)
	    (while (re-search-forward org-link-any-re
				      nil t)
	      (when (string-prefix-p "trans:" (match-string 2))
		(cl-pushnew (match-string-no-properties 3)
			    (alist-get location
				       (gethash
					(string-remove-prefix
					 "trans:"
					 (match-string-no-properties 2))
					ogt-glossary-table))
			    :test #'equal))))))
      ;; TODO: Provide more flexible window configuration.
      (setq ogt-translation-window (split-window-sensibly))
      (setq ogt-source-window (selected-window))
      (select-window ogt-translation-window)
      (ogt-goto-heading 'translation)
      ;; If we arrived via a bookmark, don't move point.
      (unless bookmark-current-bookmark
	(org-end-of-subtree))
      (ogt-prettify-segmenters)
      (ogt-update-source-location)
      (ogt-report-progress))))

(defun ogt-export-remove-segmenters (body-string _backend _plist)
  "Remove `ogt-segmentation-character' on export."
  ;; Is `org-export-filter-body-functions' the right filter to use?
  (replace-regexp-in-string
   (string ogt-segmentation-character) "" body-string))

(defun ogt-prettify-segmenters (&optional begin end)
  "Add a display face to all segmentation characters.
If BEGIN and END are given, prettify segmenters between those
locations."
  (save-excursion
    (let ((begin (or begin (point-min)))
	  (end (or end (point-max))))
      (goto-char begin)
      (while (re-search-forward
	      (string ogt-segmentation-character) end t)
	;; This marks the buffer as modified (on purpose).  Is that
	;; something we want to suppress?
	(put-text-property (1- (point)) (point)
			   ;; Any other useful thing we could do?  A
			   ;; keymap?
			   'display (string 9245))))))

(defun ogt-recenter-source ()
  "Recenter source location in the source window."
  (with-selected-window ogt-source-window
    (goto-char ogt-probable-source-location)
    (recenter)))

(defun ogt-update-source-location ()
  "Place location marker in source text.
Point must be in the translation tree for this to do anything.
Sets the marker `ogt-probable-source-location' to our best-guess
spot corresponding to where point is in the translation."
  (interactive)
  (let* ((start (point))
	 (trans-start
	  (progn (ogt-goto-heading 'translation) (point)))
	 (trans-end (progn (org-end-of-subtree) (point)))
	 (number-of-segments 0))
    (goto-char start)
    (unless (<= trans-start start trans-end)
      (user-error "Must be called from inside the translation text"))
    (while (re-search-backward (string ogt-segmentation-character)
			       trans-start t)
      (cl-incf number-of-segments))
    (with-selected-window ogt-source-window
      (ogt-goto-heading 'source)
      (save-restriction
	(org-narrow-to-subtree)
	(org-end-of-meta-data t)
	(unless (re-search-forward (string ogt-segmentation-character)
				   nil t number-of-segments)
	  t ;; Something is wrong!  Re-segment the whole buffer?
	  )
	(set-marker ogt-probable-source-location (point))
	(ogt-highlight-source-segment)
	(recenter)))
    (goto-char start)))

(defun ogt-report-progress ()
  "Report progress in the translation, as a percentage."
  (interactive)
  (let (report-start report-end)
    (save-excursion
      (save-selected-window
	(ogt-goto-heading 'source)
	(org-end-of-meta-data t)
	(setq report-start (point))
	(org-end-of-subtree)
	(setq report-end (point))))
    (message "You're %d%% done!"
	     (* (/ (float (- ogt-probable-source-location report-start))
		   (float (- report-end report-start)))
		100))))

(defun ogt-highlight-source-segment ()
  "Highlight the source segment the user is translating.
Finds the location of the `ogt-probable-source-location' marker,
and applies a highlight to the appropriate segment of text."
  (when (marker-position ogt-probable-source-location)
    (save-excursion
      (goto-char ogt-probable-source-location)
      ;; If we're right in front of a seg character, use the
      ;; following segment.
      (when (looking-at-p (string ogt-segmentation-character))
	(forward-char))
      (move-overlay
       ogt-source-segment-overlay
       (progn
	 (re-search-backward
	  (string ogt-segmentation-character)
	  nil t)
	 (1+ (point)))
       (progn
	 (or (and (re-search-forward
		   (string ogt-segmentation-character)
		   nil t)
		  (progn
		    (backward-char)
		    (skip-syntax-backward "-")
		    (point)))
	     (and (re-search-forward "\n\n" nil t)
		  (progn
		    (skip-syntax-backward "-")
		    (point)))
	     (point-max)))))))

(defun ogt-locate-heading (locator)
  "Return the ID of the heading found by LOCATOR, or nil.
Creates an ID if necessary."
  (save-excursion
    (goto-char (point-min))
    (pcase locator
      (`(heading . ,text)
       (catch 'found
	 (while (re-search-forward org-complex-heading-regexp nil t)
	   (when (string-match-p text (match-string 4))
	     (throw 'found (org-id-get-create))))))
      (`(tag . ,tag-text)
       (catch 'found
	 (while (re-search-forward org-tag-line-re nil t)
	   (when (string-match-p tag-text (match-string 2))
	     (throw 'found (org-id-get-create))))))
      (`(id . ,id-text)
       (org-id-goto id-text))
      (`(property (,prop . ,value))
       (goto-char (org-find-property prop value))
       (org-id-get-create)))))

(defun ogt-goto-heading (head)
  (let ((id (pcase head
	      ('source ogt-source-heading)
	      ('translation ogt-translation-heading)
	      ('glossary ogt-glossary-heading)
	      (_ nil))))
    (when id
      (org-id-goto id))))

(defun ogt-segment-project ()
  "Do segmentation for the current file.
Automatic segmentation is only done for the source text;
segmentation in the translation is all manual.

Segmentation is done by inserting `ogt-segmentation-character' at
the beginning of each segment."
  (dolist (loc '(source translation))
    ;; Also attempt to segment the translation subtree -- the user
    ;; might have already started.
    (save-excursion
      (ogt-goto-heading loc)
      (save-restriction
	(org-narrow-to-subtree)
	(org-end-of-meta-data t)
	(let ((mover
	       ;; These "movers" should all leave point at the beginning
	       ;; of the _next_ thing.
	       (pcase ogt-segmentation-strategy
		 ('sentence
		  (lambda (_end)
		    (forward-sentence)
		    (skip-chars-forward "[:blank:]")))
		 ('paragraph (lambda (_end)
			       (org-forward-paragraph)))
		 ((pred stringp)
		  (lambda (end)
		    (re-search-forward
		     ogt-segmentation-strategy end t)))
		 (_ (user-error
		     "Invalid value of `ogt-segmentation-strategy'"))))
	      (end (make-marker))
	      current)
	  (while (< (point) (point-max))
	    (insert ogt-segmentation-character)
	    (setq current (org-element-at-point))
	    (move-marker end (org-element-property :contents-end current))
	    ;; TODO: Do segmentation in plain lists and tables.
	    (while (and (< (point) end)
			;; END can be after `point-max' in narrowed
			;; buffer.
			(< (point) (point-max)))
	      (cond
	       ((eql (org-element-type current) 'headline)
		(skip-chars-forward "[:blank:]\\*")
		(insert ogt-segmentation-character)
		(org-end-of-meta-data t))
	       ((null (eql (org-element-type current)
			   'paragraph))
		(goto-char end))
	       (t (ignore-errors (funcall mover end))))
	      (if (eolp) ;; No good if sentence happens to end at `eol'!
		  (goto-char end)
		(insert ogt-segmentation-character)))
	    (unless (ignore-errors (org-forward-element))
	      (goto-char (point-max)))))))))

;; Could also set this as `forward-sexp-function', then don't need the
;; backward version.
(defun ogt-forward-segment (arg)
  "Move ARG segments forward.
Or backward, if ARG is negative."
  (interactive "p")
  (re-search-forward (string ogt-segmentation-character) nil t arg)
  (if (marker-position ogt-probable-source-location)
      (with-selected-window ogt-source-window
	(goto-char ogt-probable-source-location)
	(re-search-forward (string ogt-segmentation-character)
			   nil t arg)
	(set-marker ogt-probable-source-location (point))
	(ogt-highlight-source-segment)
	(recenter))
    (ogt-update-source-location)))

(defun ogt-backward-segment (arg)
  (interactive "p")
  (ogt-forward-segment (- arg)))

(defun ogt-new-segment ()
  "Start a new translation segment.
Used in the translation text when a segment is complete, to start
the next one."
  (interactive)
  (insert ogt-segmentation-character)
  (ogt-prettify-segmenters (1- (point)) (point))
  (unless (eolp)
    (forward-char))
  (recenter 10)
  (if (marker-position ogt-probable-source-location)
      (with-selected-window ogt-source-window
	(goto-char ogt-probable-source-location)
	(re-search-forward (string ogt-segmentation-character)
			   nil t)
	(set-marker ogt-probable-source-location (point))
	(ogt-highlight-source-segment)
	(recenter 10))
    (ogt-update-source-location)))

(defun ogt-add-glossary-item (string)
  "Add STRING as an item in the glossary.
If the region is active, it will be used as STRING.  Otherwise,
prompt the user for STRING."
  (interactive
   (list (if (use-region-p)
	     (buffer-substring-no-properties
	      (region-beginning)
	      (region-end))
	   (read-string "Glossary term: "))))
  (save-excursion
    (ogt-goto-heading 'glossary)
    (org-goto-first-child)
    (org-insert-heading-respect-content)
    (insert string)
    (let ((id (org-id-get-create)))
      (ogt-goto-heading 'source)
      (save-restriction
	(org-narrow-to-subtree)
	;; TODO: `string' highly likely to be broken over newlines.
	(while (re-search-forward string nil t)
	  (replace-match (format "[[trans:%s][%s]]" id string))))
      (push string (alist-get 'source (gethash id ogt-glossary-table)))))
  (message "Added %s as a glossary item" string))

(defun ogt-insert-glossary-translation ()
  "Insert a likely translation of the next glossary item."
  (interactive)
  (let ((terms-this-segment 1)
	glossary-id glossary-translation orig this-translation)
    (ogt-update-source-location)
    (save-excursion
      (while (re-search-backward "\\[\\[trans:"
				 (save-excursion
				   (re-search-backward
				    (string ogt-segmentation-character) nil t)
				   (point))
				 t)
	(cl-incf terms-this-segment))
      (with-selected-window ogt-source-window
	(goto-char ogt-probable-source-location)
	(while (null (zerop terms-this-segment))
	  (re-search-forward org-link-any-re nil t)
	  (when (string-prefix-p "trans:" (match-string 2))
	    (cl-decf terms-this-segment)))
	(setq orig (match-string-no-properties 3)
	      glossary-id (string-remove-prefix
			   "trans:" (match-string 2))
	      glossary-translation
	      (alist-get 'translation
			 (gethash glossary-id ogt-glossary-table)))))
    (setq this-translation
	  (completing-read (format "Translation of %s: " orig)
			   glossary-translation))
    (cl-pushnew
     this-translation
     (alist-get 'translation
		(gethash glossary-id ogt-glossary-table))
     :test #'equal)
    (insert (format "[[trans:%s][%s]]" glossary-id this-translation))))

(defun ogt-stop-translating (project-name)
  "Stop translating for the current file, record position.
Saves a bookmark under PROJECT-NAME."
  (interactive
   (list (or bookmark-current-bookmark
	     (let ((f-name (file-name-nondirectory
			    (file-name-sans-extension
			     (buffer-file-name)))))
	      (read-string
	       (format-prompt "Save project as" f-name)
	       nil nil f-name)))))
  (let ((rec (bookmark-make-record)))
    (bookmark-prop-set rec 'translation t)
    (bookmark-store project-name (cdr rec) nil)
    (bookmark-save)
    (message "Position recorded and saved")))

(defun ogt-start-translating (bmk)
  "Start translating a bookmarked project.
Prompts for a bookmark, and sets up the windows."
  (interactive
   (list (progn (require 'bookmark)
		(bookmark-maybe-load-default-file)
		(assoc-string
		 (completing-read
		  "Translation project: "
		  ;; "Borrowed" from `bookmark-completing-read'.
		  (lambda (string pred action)
		    (if (eq action 'metadata)
			'(metadata (category . bookmark))
		      (complete-with-action
		       action
		       (seq-filter
			(lambda (bmk)
			  (bookmark-prop-get bmk 'translation))
			bookmark-alist)
		       string pred))))
		 bookmark-alist))))
  (bookmark-jump bmk)
  (when (derived-mode-p 'org-mode)
    (org-translate-mode)))

(provide 'org-translate)
;;; org-translate.el ends here
