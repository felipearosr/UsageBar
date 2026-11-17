// Copy buttons on the install commands. The page works without this file.
for (const button of document.querySelectorAll('.copy')) {
  button.addEventListener('click', async () => {
    try {
      await navigator.clipboard.writeText(button.dataset.copy);
      button.textContent = 'Copied';
    } catch {
      button.textContent = 'Press Ctrl+C';
      const range = document.createRange();
      range.selectNodeContents(button.parentElement.querySelector('code'));
      const selection = window.getSelection();
      selection.removeAllRanges();
      selection.addRange(range);
    }
    setTimeout(() => {
      button.textContent = 'Copy';
    }, 1800);
  });
}
