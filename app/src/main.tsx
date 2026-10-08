import { StrictMode } from 'react'
import { createRoot } from 'react-dom/client'
import './index.css'
import App from './App.tsx'
import { reloadForNewVersion } from './lib/lazyRetry'

// file versi lama hilang setelah deploy baru -> ambil versi terbaru (sekali)
window.addEventListener('vite:preloadError', (e) => { if (reloadForNewVersion()) e.preventDefault() })

createRoot(document.getElementById('root')!).render(
  <StrictMode>
    <App />
  </StrictMode>,
)
