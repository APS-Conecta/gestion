"use strict";

// Reskin one-shot (patch 070): the dark theme is gone from the suite, but a `theme` key saved
// by the pre-reskin wizard would keep re-applying `dark` on every later load. Clear it once and
// apply nothing: the light theme is the only theme. This file is still loaded from every surface
// that ever applied a theme — log.twig and the streaming heredoc in DockerController.php, which
// references this same docroot file and stays byte-identical and inert (the zero-PHP rule).
try { localStorage.removeItem('theme'); } catch (e) {}
