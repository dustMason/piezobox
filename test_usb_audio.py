import unittest
from tools.build_usb_audio import descriptors

class AudioDescriptors(unittest.TestCase):
    def test_profiles_have_consistent_interfaces_and_audio_packets(self):
        for channels, companion in [(1,False),(7,False),(7,True)]:
            with self.subTest(channels=channels,companion=companion):
                data=descriptors(channels,companion)
                self.assertEqual(int.from_bytes(data[2:4],'little'),len(data))
                chunks=[];offset=0
                while offset<len(data):
                    length=data[offset];self.assertGreaterEqual(length,2)
                    chunk=data[offset:offset+length];self.assertEqual(len(chunk),length)
                    chunks.append(chunk);offset+=length
                interfaces=[c for c in chunks if c[1]==4]
                self.assertEqual(set(c[2] for c in interfaces),set(range(data[4])))
                audio_formats=[c for c in chunks if c[1:4]==bytes([0x24,2,1]) and len(c)==11]
                self.assertEqual([c[4] for c in audio_formats],[channels]+([1] if companion else []))
                for f in audio_formats:
                    self.assertEqual(f[5:8],bytes([2,16,1]))
                    self.assertEqual(int.from_bytes(f[8:11],'little'),32000)
                audio_eps=[c for c in chunks if c[1]==5 and c[3]&3==1]
                self.assertEqual(len(audio_eps),1+companion)
                for c,f in zip(audio_eps,audio_formats):
                    self.assertEqual(c[3],5) # asynchronous IN
                    self.assertTrue(c[2]&128)
                    size=int.from_bytes(c[4:6],'little')
                    self.assertEqual(size,33*f[4]*2)
                    self.assertLessEqual(size,1023)
                    self.assertEqual(c[6],1)
                self.assertTrue(any(c[1]==5 and c[2]==3 for c in chunks))
                self.assertTrue(any(c[1]==5 and c[2]==0x84 for c in chunks))
                for ac in [c for c in chunks if len(c)==9 and c[1:5]==bytes([0x24,1,0,1])]:
                    self.assertEqual(int.from_bytes(ac[5:7],'little'),30)
                    self.assertIn(ac[8],[3,5])
                for number in [3]+([5] if companion else []):
                    self.assertEqual([(c[3],c[4]) for c in interfaces if c[2]==number],[(0,0),(1,1)])

if __name__=='__main__':unittest.main()
