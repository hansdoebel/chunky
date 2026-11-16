import { mount } from 'svelte';
import App from './App.svelte';
import { initializeAppearance } from './lib/appearance';
import './styles.css';

initializeAppearance();

mount(App, { target: document.getElementById('app')! });
