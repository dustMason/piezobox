    case 0x0B01: { // SET_INTERFACE: alternate 0 stops; alternate 1 streams.
        int stream = piezo_stream_for_interface(setup.wIndex);
        if (stream >= 0 && setup.wValue <= 1 && setup.wLength == 0) {
            piezo_set_stream((unsigned)stream, setup.wValue);
        } else if (setup.wValue != 0 || setup.wIndex >= NUM_INTERFACE || setup.wLength != 0) {
            endpoint0_stall(); return;
        }
        break;
    }
    case 0x0A81: { // GET_INTERFACE
        if (setup.wIndex >= NUM_INTERFACE) { endpoint0_stall(); return; }
        int stream = piezo_stream_for_interface(setup.wIndex);
        reply_buffer[0] = stream >= 0 ? piezo_usb_active[stream] : 0;
        data = reply_buffer; datalen = 1; break;
    }
    case 0x81A2: // Sampling frequency GET_CUR / MIN / MAX / RES.
    case 0x82A2:
    case 0x83A2:
    case 0x84A2: {
        int stream = piezo_stream_for_endpoint(setup.wIndex & 0x7f);
        if (stream < 0 || !(setup.wIndex & 0x80) || setup.wValue != 0x0100 || setup.wLength != 3) {
            endpoint0_stall(); return;
        }
        uint32_t rate = setup.wRequestAndType == 0x84A2 ? 0 : PIEZO_USB_RATE;
        reply_buffer[0] = rate; reply_buffer[1] = rate >> 8; reply_buffer[2] = rate >> 16;
        data = reply_buffer; datalen = 3; break;
    }
    case 0x0122: // Fixed-rate SET_CUR; validate its payload in the OUT handler.
        if (piezo_stream_for_endpoint(setup.wIndex & 0x7f) < 0 || !(setup.wIndex & 0x80) ||
            setup.wValue != 0x0100 || setup.wLength != 3) { endpoint0_stall(); return; }
        return;
