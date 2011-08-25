;;; alert --- Growl-style notification system for Emacs

;; Copyright (C) 2011 John Wiegley

;; Author: John Wiegley <jwiegley@gmail.com>
;; Created: 24 Aug 2011
;; Version: 1.0
;; Keywords: notification emacs message
;; X-URL: https://github.com/jwiegley/alert

;; This program is free software; you can redistribute it and/or
;; modify it under the terms of the GNU General Public License as
;; published by the Free Software Foundation; either version 2, or (at
;; your option) any later version.

;; This program is distributed in the hope that it will be useful, but
;; WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
;; General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with GNU Emacs; see the file COPYING.  If not, write to the
;; Free Software Foundation, Inc., 59 Temple Place - Suite 330,
;; Boston, MA 02111-1307, USA.

;;; Commentary:

;; Alert is a Growl-workalike for Emacs that uses a common notification
;; interface with multiple, selectable "styles", whose use can be fully
;; customized by the user.  They can even use multiple styles for a given
;; event.  It pretty much works just like Growl, so I'd recommend learning
;; about how that system functions if this doesn't make sense.
;;
;; The builtin styles currently are:
;;
;;  alert-growl     - Growl itself (surprised?)
;;  alert-message   - `message', with face showing severity, with a
;;                    `ding' for high/urgent
;;  alert-error     - `error'
;;  alert-mode-line - Persistent text in the mode-line, in different
;;                    faces according to severity, similar to how ERC's
;;                    track feature works
;;  alert-fringe    - Turning the fringe a different color, based on
;;                    severity
;;
;; It's easy to create a new style, such as playing a sound, sending an
;; e-mail, logging a message to syslog, queueing text to a log file, etc.:
;;
;;   (alert-define-style 'alert-append
;;     :on-alert (lambda (...) ...)
;;     :on-clear (lambda (...) ...)
;;     :persistent nil)
;;
;; To programmers: See the docstring for `alert' for more details

(eval-when-compile
  (require 'cl))

(defgroup alert nil
  "Notification system for Emacs similar to Growl"
  :group 'emacs)

(defcustom alert-severity-colors
  '((urgent   . "red")
    (high     . "orange")
    (moderate . "yellow")
    (normal   . "green")
    (low      . "blue")
    (trivial  . "purple"))
  "Colors associated by default with Alert severities."
  :type '(alist :key-type symbol :value-type color)
  :group 'alert)

(defcustom alert-severity-faces
  '((urgent   . alert-urgent-face)
    (high     . alert-high-face)
    (moderate . alert-moderate-face)
    (normal   . alert-normal-face)
    (low      . alert-low-face)
    (trivial  . alert-trivial-face))
  "Colors associated by default with Alert severities."
  :type '(alist :key-type symbol :value-type color)
  :group 'alert)

(defcustom alert-reveal-idle-time 120
  "If idle this many seconds, show alerts that would otherwise be hidden."
  :type 'integer
  :group 'alert)

(defcustom alert-persist-idle-time 900
  "If idle this many seconds, alerts become persistent."
  :type 'integer
  :group 'alert)

(defcustom alert-fade-time 5
  "If the user is not idle, alerts disappear after this many seconds."
  :type 'integer
  :group 'alert)

(defcustom alert-hide-all-notifications nil
  "If non-nil, no alerts are ever shown to the user."
  :type 'boolean
  :group 'alert)

(defun alert-configuration-type ()
  (list 'repeat
        (list
         'list :tag "Select style if alert matches selector"
         '(repeat
           :tag "Selector"
           :doc "If there are no selectors in the list, it matches all alerts."
           (choice
            (cons :tag "Severity"
                  (const :format "" :severity)
                  (set (const :tag "Urgent" urgent)
                       (const :tag "High" high)
                       (const :tag "Moderate" moderate)
                       (const :tag "Normal" normal)
                       (const :tag "Low" low)
                       (const :tag "Trivial" trivial)))
            (cons :tag "User Status"
                  (const :format "" :status)
                  (set (const :tag "Buffer not visible" buried)
                       (const :tag "Buffer visible" visible)
                       (const :tag "Buffer selected" selected)
                       (const :tag "User Idle" idle)))
            (cons :tag "Major Mode"
                  (const :format "" :mode)
                  regexp)
            (cons :tag "Category"
                  (const :format "" :category)
                  regexp)
            (cons :tag "Title"
                  (const :format "" :title)
                  regexp)
            (cons :tag "Message"
                  (const :format "" :message)
                  regexp)
            (cons :tag "Predicate"
                  (const :format "" :predicate)
                  function)))
         (append
          (list 'choice :tag "Alert style")
          (mapcar (lambda (style)
                    (list 'const
                          :tag (or (plist-get (cdr style) :title)
                                   (symbol-name (car style)))
                          (car style)))
                  alert-styles))
         '(set :tag "Options"
               (const :tag "Persistent" :persistent)
               (const :tag "Last Style" :last)
               ;;(list :tag "Change Severity"
               ;;      (radio :tag "From"
               ;;             (const :tag "Urgent" urgent)
               ;;             (const :tag "High" high)
               ;;             (const :tag "Moderate" moderate)
               ;;             (const :tag "Normal" normal)
               ;;             (const :tag "Low" low)
               ;;             (const :tag "Trivial" trivial))
               ;;      (radio :tag "To"
               ;;             (const :tag "Urgent" urgent)
               ;;             (const :tag "High" high)
               ;;             (const :tag "Moderate" moderate)
               ;;             (const :tag "Normal" normal)
               ;;             (const :tag "Low" low)
               ;;             (const :tag "Trivial" trivial)))
               ))))

(defcustom alert-configuration '((nil log nil)
                                 (nil message nil))
  "Configure how and when alerts are displayed.
The default is to use the Emacs `message' function, which will
also `ding' the user if the :severity of the message is either
`high' or `urgent'."
  :type (alert-configuration-type)
  :group 'alert)

(defcustom alert-growl-command (executable-find "growlnotify")
  "The path to growlnotify"
  :type 'file
  :group 'alert)

(defcustom alert-growl-priorities
  '((urgent   . 2)
    (high     . 2)
    (moderate . 1)
    (normal   . 0)
    (low      . -1)
    (trivial  . -2))
  ""
  :type '(alist :key-type symbol :value-type integer)
  :group 'alert)

(defface alert-urgent-face
  '((t (:foreground "Red" :bold t)))
  "Urgent alert face."
  :group 'alert)

(defface alert-high-face
  '((t (:foreground "Dark Orange" :bold t)))
  "High alert face."
  :group 'alert)

(defface alert-moderate-face
  '((t (:foreground "Gold" :bold t)))
  "Moderate alert face."
  :group 'alert)

(defface alert-normal-face
  '((t))
  "Normal alert face."
  :group 'alert)

(defface alert-low-face
  '((t (:foreground "Dark Blue")))
  "Low alert face."
  :group 'alert)

(defface alert-trivial-face
  '((t (:foreground "Dark Purple")))
  "Trivial alert face."
  :group 'alert)

(defvar alert-styles nil)

(defun alert-define-style (name &rest plist)
  (add-to-list 'alert-styles (cons name plist))
  (put 'alert-configuration 'custom-type (alert-configuration-type)))

(alert-define-style 'ignore :title "Ignore Alert"
                    :notifier #'ignore :remover #'ignore)

(defun alert-colorize-message (message severity)
  (set-text-properties 0 (length message)
                       (list 'face (cdr (assq severity
                                              alert-severity-faces)))
                       message)
  message)

(defun alert-log-notify (info)
  (with-current-buffer
      (get-buffer-create "*Alerts*")
    (goto-char (point-max))
    (insert (format-time-string "%H:%M %p - ")
            (alert-colorize-message (plist-get info :message)
                                    (plist-get info :severity))
            ?\n)))

(defun alert-log-clear (info)
  (with-current-buffer
      (get-buffer-create "*Alerts*")
    (goto-char (point-max))
    (insert (format-time-string "%H:%M %p - ")
            "Clear: " (plist-get info :message)
            ?\n)))

(alert-define-style 'log :title "Log to *Alerts* buffer"
                    :notifier #'alert-log-notify
                    ;;:remover #'alert-log-clear
                    )

(defun alert-message-notify (info)
  (message (alert-colorize-message (plist-get info :message)
                                   (plist-get info :severity)))
  (if (memq (plist-get info :severity) '(high urgency))
      (ding)))

(defun alert-message-remove (info)
  (message ""))

(alert-define-style 'message :title "Display message in minibuffer"
                    :notifier #'alert-message-notify
                    :remover #'alert-message-remove)

(copy-face 'fringe 'alert-saved-fringe-face)

(defun alert-fringe-notify (info)
  (set-face-background 'fringe (cdr (assq (plist-get info :severity)
                                          alert-severity-colors))))

(defun alert-fringe-restore (info)
  (copy-face 'alert-saved-fringe-face 'fringe))

(alert-define-style 'fringe :title "Change the fringe color"
                    :notifier #'alert-fringe-notify
                    :remover #'alert-fringe-restore)

(defsubst alert-encode-string (str)
  (encode-coding-string str (keyboard-coding-system)))

(defun alert-growl-notify (info)
  (if alert-growl-command
      (call-process alert-growl-command nil nil nil
                    "-a" "Emacs"
                    "-n" "Emacs"
                    "-t" (alert-encode-string (plist-get info :title))
                    "-m" (alert-encode-string (plist-get info :message))
                    "-p" (number-to-string
                          (cdr (assq (plist-get info :severity)
                                     alert-growl-priorities))))
    (alert-message-notify info)))

(alert-define-style 'growl :title "Notify using Growl"
                    :notifier #'alert-growl-notify)

(defun alert-buffer-status (&optional buffer)
  (with-current-buffer (or buffer (current-buffer))
    (let ((wind (get-buffer-window)))
      (if wind
          (if (eq wind (selected-window))
              (if (and (current-idle-time)
                       (> (float-time (current-idle-time))
                          alert-reveal-idle-time))
                  'idle
                'selected)
            'visible)
        'buried))))

(defvar alert-active-alerts nil)

(defun alert-remove-when-active (remover info)
  (let ((idle-time (and (current-idle-time)
                        (float-time (current-idle-time)))))
    (cond
     ((and idle-time (> idle-time alert-persist-idle-time)))
     ((and idle-time (> idle-time alert-reveal-idle-time))
      (run-with-timer alert-fade-time nil
                      #'alert-remove-when-active remover info))
     (t
      (funcall remover info)))))

(defun alert-remove-on-command ()
  (let (to-delete)
    (dolist (alert alert-active-alerts)
      (when (eq (current-buffer) (nth 0 alert))
        (push alert to-delete)
        (if (nth 2 alert)
            (funcall (nth 2 alert) (nth 1 alert)))))
    (dolist (alert to-delete)
      (setq alert-active-alerts (delq alert alert-active-alerts)))))

;;;###autoload
(defun* alert (message &key (severity 'normal) title category
                       buffer mode data style persistent)
  "Alert the user that something has happened.
MESSAGE is what the user will see.  You may also use keyword
arguments to specify some additional details.  Here is a full
example:

  (alert \"This is a message\"
         :title \"Title\"         ;; optional title
         :category 'example       ;; a symbol to identify the message
         :mode 'text-mode         ;; normally determined automatically
         :buffer (current-buffer) ;; this is the default
         :data nil                ;; unused by alert.el itself
         :persistent nil          ;; force the alert to be persistent
                                  ;; it is best not to use this
         :style 'fringe           ;; force a given style to be used
                                  ;; this is only for debugging!
         :severity 'high)         ;; the default severity is `normal'

If no :title is given, it's assumed to be the buffer-name.  If
:buffer is nil, it is taken to be the current buffer.  Knowing
which buffer an alert comes from allows the user the easily
navigate through buffers which have unviewed alerts.  :data is an
opaque value which modules can pass through to their own styles
if they wish."
  (ignore
   (destructuring-bind
       (alert-buffer current-major-mode current-buffer-status
                     current-buffer-name)
       (with-current-buffer (or buffer (current-buffer))
         (list (current-buffer)
               (or mode major-mode)
               (alert-buffer-status)
               (buffer-name)))
     (catch 'finish
       (let ((info (list :message message
                         :title (or title current-buffer-name)
                         :severity severity
                         :category category
                         :buffer alert-buffer
                         :mode current-major-mode
                         :data data)))
         (dolist (config alert-configuration)
           (let ((style-def (cdr (assq (or style (nth 1 config))
                                       alert-styles)))
                 (options (nth 2 config)))
             (when (not
                    (memq
                     nil
                     (mapcar
                      (lambda (condition)
                        (case (car condition)
                          (:severity
                           (memq severity (cdr condition)))
                          (:status
                           (memq current-buffer-status (cdr condition)))
                          (:mode
                           (string-match (cdr condition)
                                         (symbol-name current-major-mode)))
                          (:category
                           (and category
                                (string-match (cdr condition)
                                              (if (stringp category)
                                                  category
                                                (symbol-name category)))))
                          (:title
                           (and title
                                (string-match (cdr condition) title)))
                          (:message
                           (string-match (cdr condition) message))
                          (:predicate
                           (funcall (cdr condition) info))))
                      (nth 0 config))))

               (funcall (plist-get style-def :notifier) info)

               (let ((remover (plist-get style-def :remover)))
                 (add-to-list 'alert-active-alerts
                              (list alert-buffer info remover))
                 (with-current-buffer alert-buffer
                   (add-hook 'post-command-hook
                             'alert-remove-on-command nil t))
                 (if remover
                     (run-with-timer alert-fade-time nil
                                     #'alert-remove-when-active
                                     remover info)))))))))))

(provide 'alert)

;;; alert.el ends here