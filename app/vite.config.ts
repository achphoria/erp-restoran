import react from '@vitejs/plugin-react'
import { defineConfig } from 'vite'

// https://vite.dev/config/
export default defineConfig({
  plugins: [react()],
  // GitHub Pages melayani aplikasi di /<nama-repo>/ ; diisi oleh workflow deploy
  base: process.env.BASE_PATH ?? '/',
})
