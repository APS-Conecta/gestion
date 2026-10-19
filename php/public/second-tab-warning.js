const channel = new BroadcastChannel('tab')

channel.postMessage('second-tab')
// note that listener is added after posting the message

channel.addEventListener('message', (msg) => {
    if (msg.data === 'second-tab') {
        // message received from 2nd tab
        document.getElementById('overlay').classList.add('loading')
        alert('No se pueden abrir múltiples instancias. Puede usar AIO aquí recargando la página.')
    }
});